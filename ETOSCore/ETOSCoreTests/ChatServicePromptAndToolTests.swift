// ============================================================================
// ChatServicePromptAndToolTests.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责 ChatService 的提示词注入、时间路标、工具投喂与 worldbook 相关测试。
// ============================================================================

import Testing
import Foundation
import Combine
@testable import ETOSCore

extension ChatServiceTests {
    @Test("发送时固化界面选择的 Agent 模式")
    func requestedAgentModeOverridesStalePersistedMode() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()

        var session = createPermanentTestSession(name: "Agent 模式快照测试")
        session.toolContextIsolationEnabled = true
        chatService.setCurrentSession(session)
        #expect(Persistence.saveLocalAgentMode(.chat, sessionID: session.id))

        await chatService.sendAndProcessMessage(
            content: "使用发送时选择的模式",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            requestedLocalAgentMode: .agent
        )

        #expect(Persistence.localAgentMode(sessionID: session.id) == .agent)
        await cleanup()
    }

    @Test("会话隔离无需绑定世界书即可移除历史工具调用")
    func testSessionIsolationRemovesHistoricalToolCallsWithoutWorldbook() async throws {
        await cleanup()

        var isolatedSession = ChatSession(id: UUID(), name: "历史工具隔离会话")
        isolatedSession.toolContextIsolationEnabled = true
        let historicalToolCall = InternalToolCall(
            id: "historical-tool-call",
            toolName: "test_tool",
            arguments: "{}"
        )
        let messages = [
            ChatMessage(role: .user, content: "保留这条消息"),
            ChatMessage(role: .assistant, content: "", toolCalls: [historicalToolCall]),
            ChatMessage(role: .tool, content: "不应发送", toolCalls: [historicalToolCall])
        ]

        let preparedMessages = chatService.preparedMessagesForRequest(
            from: messages,
            loadingMessageID: UUID(),
            session: isolatedSession
        )

        #expect(preparedMessages.count == 1)
        #expect(preparedMessages.first?.role == .user)
        #expect(preparedMessages.first?.content == "保留这条消息")
        #expect(!preparedMessages.contains(where: { $0.role == .tool }))
        #expect(!preparedMessages.contains(where: { !($0.toolCalls?.isEmpty ?? true) }))

        await cleanup()
    }

    @Test("Time tag is injected when preference is enabled")
    func testSystemTimePromptInjection() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        await chatService.sendAndProcessMessage(
            content: "现在几点？",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: true
        )

        let systemMessage = mockAdapter.receivedMessages?.first(where: { $0.role == .system })
        let content = systemMessage?.content ?? ""
        #expect(content.contains("<time>"))
        #expect(content.contains(TimeZone.current.identifier))
        #expect(!content.contains("ISO8601"))

        await cleanup()
    }

    @Test("OpenAI 系统时间可作为末尾 system 消息注入")
    func testSystemTimeTailPromptInjection() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        await chatService.sendAndProcessMessage(
            content: "现在几点？",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 5,
            enableStreaming: false,
            enhancedPrompt: "保持简洁",
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: true,
            systemTimeInjectionPosition: .tail
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let systemMessages = messagesExcludingConversationRuntime(sentMessages).filter { $0.role == .system }
        let firstSystemContent = systemMessages.first?.content ?? ""
        let lastMessage = sentMessages.last

        #expect(systemMessages.count == 2)
        #expect(!sentMessages.contains(where: { $0.content.contains("<app_language>") }))
        #expect(firstSystemContent.contains("<enhanced_prompt>"))
        #expect(!firstSystemContent.contains("<time>"))
        #expect(lastMessage?.role == .system)
        #expect(lastMessage?.content.contains("<time>") == true)
        #expect(lastMessage?.content.contains(TimeZone.current.identifier) == true)
        #expect(lastMessage?.content.contains("ISO8601") == false)

        await cleanup()
    }

    @Test("尾部 user 上下文按适配器顺序安全合并")
    func testTailUserContextMergesWithoutBreakingMessageOrder() throws {
        let enhancedMessage = try #require(chatService.makeEnhancedPromptMessage(
            "保持简洁",
            apiFormat: "anthropic",
            openAIUsesSystemRole: true
        ))
        let timeMessage = chatService.makeTailSystemTimeMessage(
            apiFormat: "anthropic",
            openAIUsesSystemRole: true
        )
        var anthropicMessages = [
            ChatMessage(role: .user, content: "原始问题"),
            ChatMessage(role: .system, content: "后置说明")
        ]

        chatService.appendTailContextMessage(enhancedMessage, to: &anthropicMessages, apiFormat: "anthropic")
        chatService.appendTailContextMessage(timeMessage, to: &anthropicMessages, apiFormat: "anthropic")

        #expect(anthropicMessages.count == 2)
        #expect(anthropicMessages.first?.content.contains("<enhanced_prompt>") == true)
        #expect(anthropicMessages.first?.content.contains("<time>") == true)

        var openAIMessages = [
            ChatMessage(role: .user, content: "原始问题"),
            ChatMessage(role: .system, content: "后置说明")
        ]
        let openAIEnhancedMessage = try #require(chatService.makeEnhancedPromptMessage(
            "保持简洁",
            apiFormat: "openai-compatible",
            openAIUsesSystemRole: false
        ))
        let openAITimeMessage = chatService.makeTailSystemTimeMessage(
            apiFormat: "openai-compatible",
            openAIUsesSystemRole: false
        )

        chatService.appendTailContextMessage(openAIEnhancedMessage, to: &openAIMessages, apiFormat: "openai-compatible")
        chatService.appendTailContextMessage(openAITimeMessage, to: &openAIMessages, apiFormat: "openai-compatible")

        #expect(openAIMessages.count == 3)
        #expect(openAIMessages.last?.role == .user)
        #expect(openAIMessages.last?.content.contains("<enhanced_prompt>") == true)
        #expect(openAIMessages.last?.content.contains("<time>") == true)
    }

    @Test("周期性时间路标支持自定义分钟并插入在锚点消息前")
    func testPeriodicTimeLandmark_CustomIntervalAndInsertPosition() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let oldMessage = ChatMessage(
            role: .user,
            content: "10分钟前的消息",
            requestedAt: now.addingTimeInterval(-10 * 60)
        )
        let nearMessage = ChatMessage(
            role: .assistant,
            content: "3分钟前的消息",
            requestedAt: now.addingTimeInterval(-3 * 60)
        )
        let historicalMessages = [oldMessage, nearMessage]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "现在继续聊",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 5
        )

        let sentMessages = mockAdapter.receivedMessages ?? []
        let landmarkIndex = sentMessages.firstIndex(where: {
            $0.role == .system && $0.content.contains(TimeZone.current.identifier)
        })
        let insertedIndex = try #require(landmarkIndex)
        #expect(insertedIndex + 1 < sentMessages.count)
        #expect(sentMessages[insertedIndex + 1].id == oldMessage.id)
        #expect(sentMessages[insertedIndex].content.contains("<time>"))
        #expect(!sentMessages[insertedIndex].content.contains("<periodic_time_landmark>"))
        #expect(!sentMessages[insertedIndex].content.contains("本条对话的请求时间为："))

        await cleanup()
    }

    @Test("周期性时间路标在同一时间窗口内最多注入一次")
    func testPeriodicTimeLandmark_ThrottleByIntervalWindow() async throws {
        await cleanup()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "ok")

        let now = Date()
        let session = try #require(chatService.currentSessionSubject.value)
        let historicalMessages = [
            ChatMessage(role: .user, content: "很早之前的问题", requestedAt: now.addingTimeInterval(-120 * 60)),
            ChatMessage(role: .assistant, content: "很早之前的回答", requestedAt: now.addingTimeInterval(-90 * 60))
        ]
        chatService.messagesForSessionSubject.send(historicalMessages)
        Persistence.saveMessages(historicalMessages, for: session.id)

        await chatService.sendAndProcessMessage(
            content: "第一次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let firstSentMessages = mockAdapter.receivedMessages ?? []
        let firstCount = firstSentMessages.filter { $0.role == .system && $0.content.contains(TimeZone.current.identifier) }.count
        #expect(firstCount == 1)

        await chatService.sendAndProcessMessage(
            content: "紧接着第二次请求",
            aiTemperature: 0,
            aiTopP: 1,
            systemPrompt: "",
            maxChatHistory: 20,
            enableStreaming: false,
            enhancedPrompt: nil,
            enableMemory: false,
            enableMemoryWrite: false,
            includeSystemTime: false,
            enablePeriodicTimeLandmark: true,
            periodicTimeLandmarkIntervalMinutes: 30
        )
        let secondSentMessages = mockAdapter.receivedMessages ?? []
        let secondCount = secondSentMessages.filter { $0.role == .system && $0.content.contains(TimeZone.current.identifier) }.count
        #expect(secondCount == 0)

        await cleanup()
    }

    @Test("快捷指令描述生成使用 XML 包裹上下文")
    func testShortcutDescriptionPromptUsesXMLContext() async throws {
        await cleanup()
        setupMockResponsesForChatAndTitle()
        mockAdapter.responseToReturn = ChatMessage(role: .assistant, content: "打开灯光并播放音乐")

        let description = await chatService.generateShortcutToolDescription(
            toolName: "打开 <灯> & 音乐",
            metadata: ["note": .string("A < B & C")],
            source: "if x < 1 && y > 0"
        )

        let prompt = mockAdapter.receivedMessages?.last(where: { $0.role == .user })?.content ?? ""
        #expect(description == "打开灯光并播放音乐")
        #expect(prompt.contains("<shortcut>"))
        #expect(prompt.contains("</shortcut>"))
        #expect(prompt.contains("<shortcut_name>打开 &lt;灯&gt; &amp; 音乐</shortcut_name>"))
        #expect(prompt.contains("<metadata>{\"note\":\"A &lt; B &amp; C\"}</metadata>"))
        #expect(prompt.contains("<source_summary>if x &lt; 1 &amp;&amp; y &gt; 0</source_summary>"))
        #expect(!prompt.contains("快捷指令名称："))

        await cleanup()
    }

    @Test("工具结果二次请求沿用流式设置")
    func testToolFollowUpRequestKeepsStreamingPreference() async throws {
        await cleanup()
        await memoryManager.addMemory(content: "用户喜欢喝抹茶拿铁。")
        setupMockResponsesForChatAndTitle()

        let sessionID = try #require(chatService.currentSessionSubject.value?.id)
        let loadingMessage = ChatMessage(role: .assistant, content: "", requestedAt: Date())
        chatService.updateMessages([loadingMessage], for: sessionID)

        let toolCall = InternalToolCall(
            id: "call_search_stream",
            toolName: "search_memory",
            arguments: #"{"mode":"keyword","query":"抹茶","count":1}"#
        )

        await chatService.processResponseMessage(
            responseMessage: ChatMessage(role: .assistant, content: "", toolCalls: [toolCall]),
            loadingMessageID: loadingMessage.id,
            currentSessionID: sessionID,
            userMessage: nil,
            wasTemporarySession: false,
            availableTools: [chatService.searchMemoryTool],
            aiTemperature: 0,
            aiTopP: 0,
            systemPrompt: "",
            maxChatHistory: 0,
            enableStreaming: true,
            enableMemory: true,
            enableMemoryWrite: false,
            enableMemoryActiveRetrieval: true,
            includeSystemTime: false
        )

        #expect(mockAdapter.receivedChatStreamFlags.last == true)

        await cleanup()
    }


}
