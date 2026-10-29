// ============================================================================
// ShortcutToolManagerSupport.swift
// ============================================================================
// 快捷指令工具管理器的执行、导入、回调与解析支撑。
// ============================================================================

import Foundation
import Combine
import os.log
#if os(iOS)
import UIKit
#endif

extension ShortcutToolManager {
    func executeWithFallback(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        allowRelayOnWatch: Bool,
        admission: (@Sendable () -> Bool)? = nil
    ) async -> ShortcutTransportAttempt<ShortcutToolExecutionResult> {
        let order: [ShortcutExecutionTransport] = {
            switch tool.runModeHint {
            case .bridge:
                return [.bridge, .direct]
            case .direct:
                return [.direct, .bridge]
            }
        }()

        let result = await ShortcutTransportFallback.run(transports: order) { transport in
            if Task.isCancelled || admission?() == false {
                return .stopped(cancelledExecutionResult(
                    requestID: UUID().uuidString,
                    toolName: tool.name,
                    transport: transport,
                    startedAt: Date()
                ))
            }
            return await executeLocally(tool: tool, argumentsJSON: argumentsJSON, transport: transport, admission: admission)
        }
        return result ?? .notStarted(ShortcutToolExecutionResult(
            requestID: UUID().uuidString,
            toolName: tool.name,
            success: false,
            result: nil,
            errorMessage: NSLocalizedString("快捷指令执行失败。", comment: ""),
            transport: .direct,
            startedAt: Date(),
            finishedAt: Date()
        ))
    }

    func executeLocally(
        tool: ShortcutToolDefinition,
        argumentsJSON: String,
        transport: ShortcutExecutionTransport,
        admission: (@Sendable () -> Bool)?
    ) async -> ShortcutTransportAttempt<ShortcutToolExecutionResult> {
        let requestID = UUID().uuidString
        let targetShortcutName: String
        let payloadText: String

        switch transport {
        case .direct:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        case .bridge:
            targetShortcutName = bridgeShortcutName
            payloadText = bridgePayload(for: tool, argumentsJSON: argumentsJSON, requestID: requestID)
        case .relay:
            targetShortcutName = tool.name
            payloadText = normalizedArgumentsPayload(from: argumentsJSON)
        }

        return await runShortcutAndAwaitCallback(
            requestID: requestID,
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            originalToolName: tool.name,
            transport: transport,
            admission: admission
        )
    }

    func runShortcutAndAwaitCallback(
        requestID: String,
        targetShortcutName: String,
        payloadText: String,
        originalToolName: String,
        transport: ShortcutExecutionTransport,
        admission: (@Sendable () -> Bool)?
    ) async -> ShortcutTransportAttempt<ShortcutToolExecutionResult> {
        let startAt = Date()

        guard let launchURL = buildRunShortcutURL(
            targetShortcutName: targetShortcutName,
            payloadText: payloadText,
            requestID: requestID,
            transport: transport
        ) else {
            return .notStarted(ShortcutToolExecutionResult(
                requestID: requestID,
                toolName: originalToolName,
                success: false,
                result: nil,
                errorMessage: ShortcutToolError.cannotOpenShortcutApp.localizedDescription,
                transport: transport,
                startedAt: startAt,
                finishedAt: Date()
            ))
        }

        return await withTaskCancellationHandler {
            guard !Task.isCancelled else {
                return .stopped(cancelledExecutionResult(
                    requestID: requestID,
                    toolName: originalToolName,
                    transport: transport,
                    startedAt: startAt
                ))
            }
            return await withCheckedContinuation { (continuation: CheckedContinuation<ShortcutTransportAttempt<ShortcutToolExecutionResult>, Never>) in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .stopped(cancelledExecutionResult(
                        requestID: requestID,
                        toolName: originalToolName,
                        transport: transport,
                        startedAt: startAt
                    )))
                    return
                }

                var pending = PendingExecution(
                    requestID: requestID,
                    toolName: originalToolName,
                    transport: transport,
                    startedAt: startAt,
                    continuation: continuation,
                    timeoutTask: nil
                )

                let timeoutTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await Task.sleep(nanoseconds: self.executionTimeoutSeconds * 1_000_000_000)
                    } catch {
                        return
                    }
                    self.resolvePendingAsTimeout(requestID: requestID)
                }
                pending.timeoutTask = timeoutTask
                pendingExecutions[requestID] = pending

                Task { [weak self] in
                    guard let self else { return }
                    guard self.pendingExecutions[requestID] != nil else { return }
                    guard admission?() != false else {
                        self.resolvePendingAsCancelled(requestID: requestID)
                        return
                    }
                    let opened = await self.openSystemURL(launchURL)
                    if !opened {
                        let failure = ShortcutToolExecutionResult(
                            requestID: requestID,
                            toolName: originalToolName,
                            success: false,
                            result: nil,
                            errorMessage: NSLocalizedString("快捷指令可能已启动，但无法确认执行结果。", comment: "Shortcut execution outcome unknown"),
                            transport: transport,
                            startedAt: startAt,
                            finishedAt: Date()
                        )
                        self.resolvePending(requestID: requestID, result: failure, outcomeUnknown: true)
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.resolvePendingAsCancelled(requestID: requestID)
            }
        }
    }

    func resolvePendingAsTimeout(requestID: String) {
        guard let pending = pendingExecutions[requestID] else { return }
        let result = ShortcutToolExecutionResult(
            requestID: requestID,
            toolName: pending.toolName,
            success: false,
            result: nil,
            errorMessage: NSLocalizedString("快捷指令可能已启动，但未收到回调，执行结果未知。", comment: "Shortcut callback timeout outcome unknown"),
            transport: pending.transport,
            startedAt: pending.startedAt,
            finishedAt: Date()
        )
        resolvePending(requestID: requestID, result: result, outcomeUnknown: true)
    }

    func resolvePendingAsCancelled(requestID: String) {
        guard let pending = pendingExecutions[requestID] else { return }
        resolvePending(
            requestID: requestID,
            result: cancelledExecutionResult(
                requestID: requestID,
                toolName: pending.toolName,
                transport: pending.transport,
                startedAt: pending.startedAt,
                outcomeUnknown: true
            ),
            outcomeUnknown: true
        )
    }

    func cancelledExecutionResult(
        requestID: String,
        toolName: String,
        transport: ShortcutExecutionTransport,
        startedAt: Date,
        outcomeUnknown: Bool = false
    ) -> ShortcutToolExecutionResult {
        ShortcutToolExecutionResult(
            requestID: requestID,
            toolName: toolName,
            success: false,
            result: nil,
            errorMessage: outcomeUnknown
                ? NSLocalizedString("快捷指令可能已启动，取消后执行结果未知。", comment: "Shortcut cancelled with unknown outcome")
                : NSLocalizedString("工具调用已取消。", comment: "Shortcut execution cancelled"),
            transport: transport,
            startedAt: startedAt,
            finishedAt: Date()
        )
    }

    func resolvePending(requestID: String, result: ShortcutToolExecutionResult, outcomeUnknown: Bool = false) {
        guard var pending = pendingExecutions.removeValue(forKey: requestID) else { return }
        pending.timeoutTask?.cancel()
        pending.timeoutTask = nil
        pending.continuation.resume(returning: outcomeUnknown ? .outcomeUnknown(result) : .completed(result))
    }

    func buildRunShortcutURL(
        targetShortcutName: String,
        payloadText: String,
        requestID: String,
        transport: ShortcutExecutionTransport
    ) -> URL? {
        var callbackComponents = URLComponents()
        callbackComponents.scheme = ShortcutURLRouter.appScheme
        callbackComponents.host = "shortcuts"
        callbackComponents.path = "/callback"

        var successComponents = callbackComponents
        successComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "success"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        var errorComponents = callbackComponents
        errorComponents.queryItems = [
            URLQueryItem(name: "request_id", value: requestID),
            URLQueryItem(name: "status", value: "error"),
            URLQueryItem(name: "transport", value: transport.rawValue)
        ]

        guard let successURL = successComponents.url?.absoluteString,
              let errorURL = errorComponents.url?.absoluteString else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [
            URLQueryItem(name: "name", value: targetShortcutName),
            URLQueryItem(name: "input", value: "text"),
            URLQueryItem(name: "text", value: payloadText),
            URLQueryItem(name: "x-success", value: successURL),
            URLQueryItem(name: "x-error", value: errorURL)
        ]
        return components.url
    }

}
