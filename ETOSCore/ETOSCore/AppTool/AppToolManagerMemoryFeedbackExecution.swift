// ============================================================================
// AppToolManagerMemoryFeedbackExecution.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载反馈工单执行逻辑。
// ============================================================================

import Foundation

extension AppToolManager {
    func executeSubmitFeedbackTicket(argumentsJSON: String) async throws -> String {
        struct SubmitFeedbackArgs: Decodable {
            let category: String?
            let title: String
            let detail: String
            let reproduction_steps: String?
            let expected_behavior: String?
            let actual_behavior: String?
            let extra_context: String?
            let linux_runtime_diagnostic_id: String?
        }

        guard let argsData = argumentsJSON.data(using: .utf8),
              let args = try? JSONDecoder().decode(SubmitFeedbackArgs.self, from: argsData) else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：无法解析 submit_feedback_ticket 的参数，请至少提供 title 和 detail。", comment: "Submit feedback ticket invalid arguments")
            )
        }

        let normalizedCategoryRaw = args.category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let category: FeedbackCategory
        if let normalizedCategoryRaw, !normalizedCategoryRaw.isEmpty {
            guard let parsedCategory = FeedbackCategory(rawValue: normalizedCategoryRaw) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：submit_feedback_ticket 的 category 仅支持 bug 或 suggestion。", comment: "Submit feedback ticket invalid category")
                )
            }
            category = parsedCategory
        } else {
            category = .bug
        }

        let title = args.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = args.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !detail.isEmpty else {
            throw AppToolExecutionError.invalidArguments(
                NSLocalizedString("错误：submit_feedback_ticket 的 title 和 detail 不能为空。", comment: "Submit feedback ticket empty title or detail")
            )
        }

        var extraContext = args.extra_context
        if let rawDiagnosticID = args.linux_runtime_diagnostic_id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDiagnosticID.isEmpty {
            guard let diagnosticID = UUID(uuidString: rawDiagnosticID),
                  let diagnostic = Persistence.loadLocalLinuxDiagnostic(id: diagnosticID) else {
                throw AppToolExecutionError.invalidArguments(
                    NSLocalizedString("错误：找不到指定的 Linux 运行时诊断。", comment: "Submit feedback ticket missing Linux diagnostic")
                )
            }
            var safeDiagnostic: [String: Any] = [
                "diagnostic_id": diagnostic.id.uuidString,
                "category": diagnostic.category.rawValue,
                "request_id": diagnostic.requestID,
                "guest_architecture": diagnostic.guestArchitecture,
                "backend": diagnostic.backend,
                "build_identity": diagnostic.buildIdentity,
                "occurrence_count": diagnostic.occurrenceCount,
                "summary": diagnostic.redactedSummary
            ]
            safeDiagnostic["seed_version"] = diagnostic.seedVersion
            safeDiagnostic["exit_code"] = diagnostic.exitCode
            safeDiagnostic["signal"] = diagnostic.signal
            safeDiagnostic["linux_errno"] = diagnostic.linuxError
            safeDiagnostic["completion_reason"] = diagnostic.completionReason?.rawValue
            safeDiagnostic["guest_pc"] = diagnostic.guestProgramCounter
            safeDiagnostic["opcode"] = diagnostic.opcode
            safeDiagnostic["guest_process_id"] = diagnostic.guestProcessID
            safeDiagnostic["guest_thread_group_id"] = diagnostic.guestThreadGroupID
            safeDiagnostic["process_name"] = diagnostic.processName
            safeDiagnostic["syscall_number"] = diagnostic.systemCallNumber
            safeDiagnostic["syscall_name"] = diagnostic.systemCallName
            let serializedDiagnostic = prettyPrintedJSONString(from: safeDiagnostic)
            let prefix = extraContext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let diagnosticHeading = NSLocalizedString("Linux 运行时诊断：", comment: "Feedback Linux runtime diagnostic heading")
            extraContext = prefix.isEmpty
                ? "\(diagnosticHeading)\n\(serializedDiagnostic)"
                : prefix + "\n\n\(diagnosticHeading)\n" + serializedDiagnostic
        }

        let draft = FeedbackDraft(
            category: category,
            title: args.title,
            detail: args.detail,
            reproductionSteps: args.reproduction_steps,
            expectedBehavior: args.expected_behavior,
            actualBehavior: args.actual_behavior,
            extraContext: extraContext
        )
        let ticket = try await FeedbackService.shared.submit(draft: draft)
        let formatter = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "issueNumber": ticket.issueNumber,
            "category": ticket.category.rawValue,
            "title": ticket.title,
            "status": ticket.lastKnownStatus.rawValue,
            "createdAt": formatter.string(from: ticket.createdAt),
            "publicURL": ticket.publicURL?.absoluteString as Any,
            "moderationBlocked": ticket.moderationBlocked as Any,
            "moderationMessage": ticket.moderationMessage as Any
        ]
        if AchievementTriggerEvaluator.shouldUnlockFishTankReview(appToolName: AppToolKind.submitFeedbackTicket.toolName),
           !AchievementCenter.shared.hasUnlocked(id: .fishTankReview) {
            await AchievementCenter.shared.unlock(id: .fishTankReview)
        }
        return prettyPrintedJSONString(from: payload)
    }

}
