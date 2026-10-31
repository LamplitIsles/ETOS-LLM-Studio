// ============================================================================
// ChatViewMessageSheets.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件承载聊天页的消息操作、会话信息与消息详情弹窗组件。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct MessageActionSheet: View {
    private static let imageOnlyPlaceholders: Set<String> = [
        "[图片]", "[圖片]", "[Image]", "[画像]", "[Imagen]", "[صورة]", "[Изображение]"
    ]

    let payload: MessageActionSheetPayload
    let isUserContentTruncated: Bool
    let hasDisplayVersions: Bool
    let displayVersionCount: Int
    let displayCurrentVersionIndex: Int
    let canRetry: Bool
    let canPrefill: Bool
    let allMessages: [ChatMessage]
    let providers: [Provider]
    @ObservedObject var ttsManager: TTSManager
    let onEdit: (ChatMessage) -> Void
    let onRetry: (ChatMessage) -> Void
    let onPrefill: (ChatMessage) -> Void
    let onShowFullError: (String) -> Void
    let onBranch: (ChatMessage) -> Void
    let onExport: (ChatTranscriptExportFormat, Bool, Bool, ChatMessage?) -> Void
    let onSpeak: (ChatMessage) -> Void
    let onSwitchVersion: (Int, ChatMessage) -> Void
    let onDeleteVersion: (ChatMessage, Int) -> Void
    let onDelete: (ChatMessage) -> Void
    let onDownloadImages: (ChatMessage) -> Void
    let onConvertMarkdownImages: (ChatMessage) -> Void
    let onRetryVideoAnalysis: (ChatMessage, String) async throws -> VideoAnalysisResult
    let onAskAI: (String, ChatMessage) -> Void
    let onSelectMultiple: (ChatMessage) -> Void
    let onJumpToMessage: (Int) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var includeReasoning = true
    @State private var includeSystemPrompt = true
    @State private var jumpInput: String = ""
    @State private var jumpError: String?
    @State private var videoAnalysisOverrides: [String: VideoAnalysisResult] = [:]
    @State private var retryingVideoFileNames: Set<String> = []
    @State private var videoAnalysisErrorMessage: String?
    @State private var hasInlineMarkdownImages = false
    @State private var inlineContents: [InlineHTMLContent] = []

    private var message: ChatMessage {
        payload.message
    }

    private var hasAttachments: Bool {
        message.audioFileName != nil
            || (message.imageFileNames?.isEmpty == false)
            || (message.fileFileNames?.isEmpty == false)
    }

    private var hasImageAttachments: Bool {
        !(message.imageFileNames ?? []).isEmpty
    }

    private var hasTextBubblePayload: Bool {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasContent = !content.isEmpty && !Self.imageOnlyPlaceholders.contains(content)
        let hasReasoning = !(message.reasoningContent ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return hasContent || hasReasoning || !(message.toolCalls ?? []).isEmpty
    }

    private var videoFileNames: [String] {
        (message.fileFileNames ?? []).filter { VideoAttachmentSupport.isVideo(fileName: $0) }
    }

    private var messageIndex: Int? {
        allMessages.firstIndex(where: { $0.id == message.id })
    }

    private var displayIndex: Int? {
        messageIndex.map { $0 + 1 }
    }

    private var totalMessageCount: Int {
        allMessages.count
    }

    private var resolvedCostEstimate: MessageCostEstimate? {
        let estimate = MessageCostResolver.resolvedCost(
            for: message,
            providers: providers
        )
        guard let estimate, estimate.totalCost > 0 else { return nil }
        return estimate
    }

    private var isSpeakingThisMessage: Bool {
        ttsManager.currentSpeakingMessageID == message.id && ttsManager.isSpeaking
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    InlineHTMLMessageActionsLink(message: message, contents: inlineContents)

                    if message.role == .user, isUserContentTruncated {
                        NavigationLink {
                            FullMessageContentView(content: message.content)
                        } label: {
                            Label(NSLocalizedString("查看完整内容", comment: ""), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    if !hasAttachments {
                        Button {
                            onEdit(message)
                        } label: {
                            Label(NSLocalizedString("编辑", comment: ""), systemImage: "pencil")
                        }
                    }

                    if canRetry {
                        Button {
                            onRetry(message)
                        } label: {
                            Label(NSLocalizedString("重试", comment: ""), systemImage: "arrow.clockwise")
                        }
                        if canPrefill && message.canPrefill {
                            Button {
                                onPrefill(message)
                            } label: {
                                Label(NSLocalizedString("预填充续写", comment: ""), systemImage: "text.append")
                            }
                        }
                    }

                    if message.role == .error, let fullContent = message.fullErrorContent {
                        Button {
                            onShowFullError(fullContent)
                        } label: {
                            Label(NSLocalizedString("查看完整响应", comment: ""), systemImage: "doc.text.magnifyingglass")
                        }
                    }

                    Button {
                        onBranch(message)
                    } label: {
                        Label(NSLocalizedString("从此处创建分支", comment: ""), systemImage: "arrow.triangle.branch")
                    }

                    if message.role == .assistant || message.role == .tool || message.role == .system {
                        Button {
                            onSpeak(message)
                        } label: {
                            Label(
                                isSpeakingThisMessage ? NSLocalizedString("停止朗读", comment: "") : NSLocalizedString("朗读消息", comment: ""),
                                systemImage: isSpeakingThisMessage ? "stop.circle" : "speaker.wave.2"
                            )
                        }
                    }

                    NavigationLink {
                        MessageTextSelectionView(message: message) { selectedText in
                            onAskAI(selectedText, message)
                        }
                    } label: {
                        Label(
                            NSLocalizedString("选定文字", comment: "Open message text selection"),
                            systemImage: "character.cursor.ibeam"
                        )
                    }

                    Button {
                        onSelectMultiple(message)
                    } label: {
                        Label(NSLocalizedString("多选", comment: "Enter message selection mode"), systemImage: "checkmark.circle")
                    }

                    if hasInlineMarkdownImages {
                        Button {
                            onConvertMarkdownImages(message)
                        } label: {
                            Label(
                                NSLocalizedString("转为图片附件", comment: "Convert inline Markdown images to attachments"),
                                systemImage: "photo.badge.arrow.down"
                            )
                        }
                    }

                    if hasImageAttachments || hasInlineMarkdownImages {
                        Button {
                            onDownloadImages(message)
                        } label: {
                            Label(
                                NSLocalizedString("下载", comment: "Download message images"),
                                systemImage: "square.and.arrow.down"
                            )
                        }
                    }
                }

                if !hasImageAttachments || hasTextBubblePayload {
                    Section {
                        Button(role: .destructive) {
                            onDelete(message)
                        } label: {
                            Label(
                                hasImageAttachments
                                    ? NSLocalizedString("删除气泡", comment: "Delete text bubble but keep image attachments")
                                    : (hasDisplayVersions
                                        ? NSLocalizedString("删除所有版本", comment: "")
                                        : NSLocalizedString("删除消息", comment: "")),
                                systemImage: "trash.fill"
                            )
                        }
                    }
                }

                if hasDisplayVersions {
                    Section(NSLocalizedString("版本管理", comment: "")) {
                        ForEach(0..<displayVersionCount, id: \.self) { index in
                            Button {
                                onSwitchVersion(index, message)
                            } label: {
                                MessageVersionRow(
                                    index: index,
                                    isCurrent: index == displayCurrentVersionIndex
                                )
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if displayVersionCount > 1 {
                                    Button(role: .destructive) {
                                        onDeleteVersion(message, index)
                                    } label: {
                                        Label(NSLocalizedString("删除", comment: ""), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }

                videoAnalysisSections
                messageSupplementarySections
                exportSection
                messageInfoSection
            }
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .navigationTitle(NSLocalizedString("消息操作", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("完成", comment: "")) {
                        dismiss()
                    }
                }
            }
        }
        .alert(NSLocalizedString("视频解析失败", comment: "Video analysis failure alert title"), isPresented: Binding(
            get: { videoAnalysisErrorMessage != nil },
            set: { if !$0 { videoAnalysisErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("确定", comment: ""), role: .cancel) {
                videoAnalysisErrorMessage = nil
            }
        } message: {
            Text(videoAnalysisErrorMessage ?? "")
        }
        .task(id: message.content) {
            inlineContents = InlineHTMLContentRegistry.shared.contents(messageID: message.id, versionIndex: message.getCurrentVersionIndex())
            let content = message.content
            let containsImage = await Task.detached(priority: .utility) {
                MarkdownImageReferenceSupport.hasDownloadableImage(in: content)
            }.value
            guard !Task.isCancelled else { return }
            hasInlineMarkdownImages = containsImage
        }
    }

    @ViewBuilder
    private var videoAnalysisSections: some View {
        ForEach(videoFileNames, id: \.self) { fileName in
            Section {
                if let result = resolvedVideoAnalysis(for: fileName) {
                    NavigationLink {
                        VideoAnalysisDetailView(result: result)
                    } label: {
                        Label(NSLocalizedString("查看视频解析", comment: "View video analysis action"), systemImage: "doc.text.magnifyingglass")
                    }
                } else {
                    Label(NSLocalizedString("暂无视频解析结果", comment: "No video analysis result"), systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                }

                Button {
                    retryVideoAnalysis(fileName: fileName)
                } label: {
                    if retryingVideoFileNames.contains(fileName) {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("正在重新解析视频…", comment: "Retrying video analysis progress"))
                        }
                    } else {
                        Label(NSLocalizedString("重新解析视频", comment: "Retry video analysis action"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(retryingVideoFileNames.contains(fileName))
            } header: {
                Text(fileName)
            } footer: {
                Text(NSLocalizedString("重新解析会替换已保存的结果，之后发送时会使用新内容。", comment: "Video analysis retry footer"))
            }
        }
    }

    private func resolvedVideoAnalysis(for fileName: String) -> VideoAnalysisResult? {
        videoAnalysisOverrides[fileName] ?? message.videoAnalysisResult(for: fileName)
    }

    private func retryVideoAnalysis(fileName: String) {
        retryingVideoFileNames.insert(fileName)
        Task { @MainActor in
            defer { retryingVideoFileNames.remove(fileName) }
            do {
                videoAnalysisOverrides[fileName] = try await onRetryVideoAnalysis(message, fileName)
            } catch is CancellationError {
            } catch {
                videoAnalysisErrorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section {
            Toggle(NSLocalizedString("包含思考", comment: ""), isOn: $includeReasoning)
            Toggle(NSLocalizedString("包含系统提示词", comment: ""), isOn: $includeSystemPrompt)

            ForEach(MessageActionExportScope.allCases) { scope in
                Menu {
                    ForEach(ChatTranscriptExportFormat.allCases, id: \.self) { format in
                        Button {
                            onExport(
                                format,
                                includeReasoning,
                                includeSystemPrompt,
                                scope == .upToMessage ? message : nil
                            )
                        } label: {
                            Label(format.displayName, systemImage: iconName(for: format))
                        }
                    }
                } label: {
                    Label(
                        exportScopeTitle(scope),
                        systemImage: scope == .upToMessage ? "arrow.up.doc" : "square.and.arrow.up"
                    )
                }
            }
        } header: {
            Text(NSLocalizedString("导出", comment: ""))
        } footer: {
            Text(NSLocalizedString("PNG 仅导出聊天界面可见内容，不会包含系统提示词。", comment: "Chat image export system prompt privacy note"))
        }
    }

    @ViewBuilder
    private var messageInfoSection: some View {
        Section(NSLocalizedString("消息信息", comment: "")) {
            LabeledContent(NSLocalizedString("角色", comment: "")) {
                Text(roleDescription(message.role))
            }

            if let displayIndex {
                LabeledContent(NSLocalizedString("列表位置", comment: "")) {
                    Text(
                        String(
                            format: NSLocalizedString("第 %d / %d 条", comment: ""),
                            displayIndex,
                            totalMessageCount
                        )
                    )
                }
            }

            if let modelReference = message.modelReference {
                LabeledContent(NSLocalizedString("提供商", comment: "")) {
                    Text(modelReference.providerName)
                        .textSelection(.enabled)
                }
                LabeledContent(NSLocalizedString("模型名称", comment: "")) {
                    Text(modelReference.modelDisplayName)
                        .textSelection(.enabled)
                }
                LabeledContent(NSLocalizedString("模型ID", comment: "")) {
                    Text(modelReference.modelName)
                        .textSelection(.enabled)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("唯一标识", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
                Text(message.id.uuidString)
                    .etFont(.footnote.monospaced())
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private var messageSupplementarySections: some View {
        if totalMessageCount > 0 {
            Section(NSLocalizedString("快速定位", comment: "Quick message jump section title")) {
                TextField(
                    String(
                        format: NSLocalizedString("输入消息序号（1-%d）", comment: "Message index input placeholder"),
                        totalMessageCount
                    ),
                    text: $jumpInput
                )
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit {
                    submitJump()
                }

                Button {
                    submitJump()
                } label: {
                    Label(NSLocalizedString("跳转到该条消息", comment: "Jump to message button title"), systemImage: "location")
                }

                if let jumpError, !jumpError.isEmpty {
                    Text(jumpError)
                        .etFont(.footnote)
                        .foregroundStyle(.red)
                }
            }
        }

        if let usage = message.tokenUsage, usage.hasData {
            Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                if let prompt = usage.promptTokens {
                    LabeledContent(NSLocalizedString("发送 Tokens", comment: "Prompt tokens label")) {
                        Text("\(prompt)")
                    }
                }
                if let completion = usage.completionTokens {
                    LabeledContent(NSLocalizedString("接收 Tokens", comment: "Completion tokens label")) {
                        Text("\(completion)")
                    }
                }
                if let thinking = usage.thinkingTokens {
                    LabeledContent(NSLocalizedString("思考 Tokens", comment: "Thinking tokens label")) {
                        Text("\(thinking)")
                    }
                }
                if let cacheWrite = usage.cacheWriteTokens, cacheWrite > 0 {
                    LabeledContent(NSLocalizedString("缓存写入 Tokens", comment: "Cache write tokens label")) {
                        Text("\(cacheWrite)")
                    }
                }
                if let cacheRead = usage.cacheReadTokens, cacheRead > 0 {
                    LabeledContent(NSLocalizedString("缓存读取 Tokens", comment: "Cache read tokens label")) {
                        Text("\(cacheRead)")
                    }
                }
                if let total = usage.totalTokens, (usage.promptTokens != total || usage.completionTokens != total) {
                    LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                        Text("\(total)")
                    }
                } else if let totalOnly = usage.totalTokens, usage.promptTokens == nil && usage.completionTokens == nil {
                    LabeledContent(NSLocalizedString("总计", comment: "Total tokens label")) {
                        Text("\(totalOnly)")
                    }
                }
                if let costEstimate = resolvedCostEstimate {
                    MessageCostDetailRows(estimate: costEstimate)
                }
            }
        } else if let metrics = message.responseMetrics, metrics.isTokenPerSecondEstimated {
            Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                Text(NSLocalizedString("当前响应未返回官方 token 用量（仅有估算速度）。", comment: "No official token usage returned hint"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
                if let costEstimate = resolvedCostEstimate {
                    MessageCostDetailRows(estimate: costEstimate)
                }
            }
        } else if let costEstimate = resolvedCostEstimate {
            Section(NSLocalizedString("Token 用量", comment: "Token usage section title")) {
                MessageCostDetailRows(estimate: costEstimate)
            }
        }

        if let metrics = message.responseMetrics,
           metrics.timeToFirstToken != nil
            || metrics.totalResponseDuration != nil
            || metrics.reasoningDuration != nil
            || metrics.completionTokensForSpeed != nil
            || metrics.tokenPerSecond != nil {
            Section(NSLocalizedString("响应测速", comment: "Response speed metrics section title")) {
                if let firstToken = metrics.timeToFirstToken {
                    LabeledContent(NSLocalizedString("首字时间", comment: "Time to first token")) {
                        Text(formatDuration(firstToken))
                    }
                }
                if let totalDuration = metrics.totalResponseDuration {
                    LabeledContent(NSLocalizedString("总回复时间", comment: "Total response time")) {
                        Text(formatDuration(totalDuration))
                    }
                }
                if let reasoningDuration = metrics.reasoningDuration {
                    LabeledContent(NSLocalizedString("思考耗时", comment: "Reasoning duration")) {
                        Text(formatDuration(reasoningDuration))
                    }
                }
                if let completionTokens = metrics.completionTokensForSpeed {
                    LabeledContent(NSLocalizedString("测速 Tokens", comment: "Tokens used for speed calculation")) {
                        Text("\(completionTokens)")
                    }
                }
                if let speed = metrics.tokenPerSecond {
                    LabeledContent(NSLocalizedString("响应速度", comment: "Response speed")) {
                        Text(formatSpeed(speed, estimated: metrics.isTokenPerSecondEstimated))
                    }
                }
            }
        }

        if let metrics = message.responseMetrics,
           let samples = metrics.speedSamples,
           !samples.isEmpty {
            Section(NSLocalizedString("流式速度曲线", comment: "Streaming speed chart title")) {
                MessageInfoStreamingSpeedChart(metrics: metrics)
            }
        }
    }

    private func roleDescription(_ role: MessageRole) -> String {
        switch role {
        case .system:
            return NSLocalizedString("系统", comment: "")
        case .user:
            return NSLocalizedString("用户", comment: "")
        case .assistant:
            return NSLocalizedString("助手", comment: "")
        case .tool:
            return NSLocalizedString("工具", comment: "")
        case .error:
            return NSLocalizedString("错误", comment: "")
        @unknown default:
            return NSLocalizedString("未知", comment: "")
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let clamped = max(0, duration)
        return String(format: "%.2fs", clamped)
    }

    private func formatSpeed(_ speed: Double, estimated: Bool) -> String {
        let base = String(format: "%.2f %@", max(0, speed), NSLocalizedString("token/s", comment: "Tokens per second unit"))
        if estimated {
            return "\(base) (\(NSLocalizedString("估算", comment: "Estimated")))"
        }
        return base
    }

    private func submitJump() {
        let trimmed = jumpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let displayIndex = Int(trimmed) else {
            jumpError = NSLocalizedString("请输入有效的序号。", comment: "Invalid message index hint")
            return
        }

        guard displayIndex >= 1 && displayIndex <= totalMessageCount else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessageCount
            )
            return
        }

        guard onJumpToMessage(displayIndex) else {
            jumpError = String(
                format: NSLocalizedString("序号超出范围，请输入 1 到 %d。", comment: "Out of range message index hint"),
                totalMessageCount
            )
            return
        }

        jumpError = nil
        dismiss()
    }

    private func exportScopeTitle(_ scope: MessageActionExportScope) -> String {
        switch scope {
        case .fullSession:
            return NSLocalizedString("导出整个会话", comment: "")
        case .upToMessage:
            return NSLocalizedString("导出到此消息（含上文）", comment: "")
        }
    }

    private func iconName(for format: ChatTranscriptExportFormat) -> String {
        switch format {
        case .pdf:
            return "doc.richtext"
        case .markdown:
            return "number.square"
        case .text:
            return "doc.plaintext"
        case .png:
            return "photo"
        }
    }
}

struct VideoAnalysisDetailView: View {
    let result: VideoAnalysisResult

    var body: some View {
        List {
            Section(NSLocalizedString("视频", comment: "Video analysis detail video section")) {
                LabeledContent(NSLocalizedString("文件名", comment: ""), value: result.fileName)
                LabeledContent(NSLocalizedString("解析模型", comment: "Video analysis model detail"), value: result.modelDisplayName)
                LabeledContent(NSLocalizedString("解析时间", comment: "Video analysis date detail")) {
                    Text(result.generatedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section(NSLocalizedString("解析文字", comment: "Video analysis text section")) {
                Text(result.content)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(NSLocalizedString("视频解析", comment: "Video analysis detail title"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MessageVersionRow: View {
    let index: Int
    let isCurrent: Bool

    var body: some View {
        Label {
            HStack(spacing: 8) {
                Text(String(format: NSLocalizedString("版本 %d", comment: ""), index + 1))
                Spacer()
                if isCurrent {
                    Text(NSLocalizedString("当前", comment: ""))
                        .foregroundStyle(.secondary)
                }
            }
        } icon: {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
    }
}
