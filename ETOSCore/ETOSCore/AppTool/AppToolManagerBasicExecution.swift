// ============================================================================
// AppToolManagerBasicExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载本地拓展工具中的基础交互类工具执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeShowWidget(argumentsJSON: String) throws -> String {
        struct ShowWidgetArgs: Decodable {
            let title: String?
            let widget_code: String
            let loading_messages: [String]?
            let inline_aspect_ratio: String?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(ShowWidgetArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 show_widget 的参数，请提供 widget_code。", comment: "Show widget tool invalid arguments")
            )
        }

        let widgetCode = args.widget_code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !widgetCode.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：show_widget 的 widget_code 不能为空。", comment: "Show widget tool empty widget code")
            )
        }

        let normalizedTitle = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedAspectRatio = args.inline_aspect_ratio
            .flatMap(ToolWidgetAspectRatio.init(rawValue:)) ?? .standard
        let normalizedLoadingMessages = (args.loading_messages ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload: [String: Any] = [
            "title": normalizedTitle as Any,
            "widget_code": widgetCode,
            "inline_aspect_ratio": normalizedAspectRatio.rawValue,
            "loading_messages": normalizedLoadingMessages
        ]
        return prettyPrintedJSONString(from: payload)
    }

    func executeEchoText(argumentsJSON: String) throws -> String {
        struct EchoArgs: Decodable {
            let text: String
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(EchoArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 echo_text 的参数，请提供 text 字段。", comment: "Echo tool invalid arguments")
            )
        }

        let text = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：echo_text 的 text 不能为空。", comment: "Echo tool empty text")
            )
        }

        return String(
            format: NSLocalizedString("文本回显结果：%@", comment: "Echo tool result format"),
            text
        )
    }

    func executeFillUserInput(
        argumentsJSON: String,
        sourceSessionID: UUID?,
        sourceMessageID: UUID?
    ) throws -> String {
        struct FillUserInputArgs: Decodable {
            let text: String
            let mode: String?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(FillUserInputArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 fill_user_input 的参数，请提供 text。", comment: "Fill user input tool invalid arguments")
            )
        }

        let content = args.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：fill_user_input 的 text 不能为空。", comment: "Fill user input tool empty text")
            )
        }

        let mode = AppToolInputDraftMode(rawValue: (args.mode ?? AppToolInputDraftMode.replace.rawValue).lowercased()) ?? .replace
        let request = AppToolInputDraftRequest(
            text: args.text,
            mode: mode,
            sourceSessionID: sourceSessionID,
            sourceMessageID: sourceMessageID
        )
        let receipt = AppToolUIRequestDeliveryReceipt()
        var userInfo = request.userInfo
        userInfo[AppToolUIRequestDeliveryReceipt.userInfoKey] = receipt
        NotificationCenter.default.post(
            name: .appToolFillUserInputRequested,
            object: nil,
            userInfo: userInfo
        )
        guard let delivery = receipt.delivery else {
            throw AppToolExecutionError.uiRequestUnavailable
        }

        let payload: [String: Any] = [
            "mode": mode.rawValue,
            "characterCount": args.text.count,
            "applied": delivery == .applied,
            "queued": delivery == .queued
        ]
        return prettyPrintedJSONString(from: payload)
    }
}
