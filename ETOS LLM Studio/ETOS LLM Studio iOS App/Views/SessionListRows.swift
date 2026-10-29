// ============================================================================
// SessionListRows.swift
// ============================================================================
// ETOS LLM Studio
//
// 提供 iOS 会话列表的行组件、批量选择行与会话信息 Sheet。
// 行采用卡片样式（圆角 14、淡描边、当前会话三重强调），适合分组浏览。
// ============================================================================

import Foundation
import ETOSCore
import SwiftUI

struct SessionMergedEntryWithRank {
    let rank: Int
    let entry: SessionMergedEntry
}

enum SessionMergedEntry: Identifiable {
    case folder(SessionFolder)
    case session(ChatSession)

    var id: String {
        switch self {
        case .folder(let folder):
            return "folder-\(folder.id.uuidString)"
        case .session(let session):
            return "session-\(session.id.uuidString)"
        }
    }
}

/// 统一文件夹和会话的原生选择标识，避免不同类型的相同 UUID 发生冲突。
enum SessionBatchSelectionID: Hashable {
    case folder(UUID)
    case session(UUID)
}

extension SessionMergedEntry {
    var batchSelectionID: SessionBatchSelectionID {
        switch self {
        case .folder(let folder):
            return .folder(folder.id)
        case .session(let session):
            return .session(session.id)
        }
    }
}

struct SessionMoveFolderOption: Identifiable {
    let id: UUID
    let title: String
}

// MARK: - 通用卡片容器

/// 会话/文件夹行的统一卡片背景，包含当前态高亮、左侧强调条与描边。
struct SessionRowCard<Content: View>: View {
    let isCurrent: Bool
    let content: () -> Content

    init(isCurrent: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.isCurrent = isCurrent
        self.content = content
    }

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        isCurrent
                            ? Color.accentColor.opacity(0.10)
                            : Color(.secondarySystemGroupedBackground)
                    )
            }
            .overlay(alignment: .leading) {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3)
                        .padding(.vertical, 10)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isCurrent
                            ? Color.accentColor.opacity(0.35)
                            : Color(.separator).opacity(0.35),
                        lineWidth: 0.5
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - 分组标题

/// 列表分组标题（文件夹 / 会话 / 搜索结果），样式贴近邮件 App。
struct SessionGroupHeader: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 批量选择行

// 选择控件与连续选择手势由 List(selection:) 提供，行内不拦截滚动触摸。

struct BatchSelectableFolderRow: View {
    let folder: SessionFolder
    let sessionCount: Int
    let tags: [SessionTag]

    var body: some View {
        SessionRowCard(isCurrent: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(folder.name)
                        .etFont(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                Text(String(format: NSLocalizedString("%d 个会话", comment: ""), sessionCount))
                    .etFont(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                SessionTagInlineList(tags: tags)
            }
        }
    }
}

struct BatchSelectableSessionRow: View {
    let session: ChatSession
    let tags: [SessionTag]

    var body: some View {
        SessionRowCard(isCurrent: false) {
            SessionListRowContentBody(
                title: session.name,
                subtitle: nil,
                footnote: nil,
                tags: tags,
                isCurrent: false,
                isRunning: false
            )
        }
    }
}

// MARK: - 普通会话行

struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let isRunning: Bool
    let runtimeState: ConversationRuntimeSessionState?
    let isEditing: Bool
    @Binding var draftName: String
    let currentFolderID: UUID?
    let moveOptions: [SessionMoveFolderOption]
    let tags: [SessionTag]
    let searchSummary: String?
    let locationSummary: String?

    let onCommit: (String) -> Void
    let onSelect: () -> Void
    let onRename: () -> Void
    let onBranch: (Bool) -> Void
    let onMoveToFolder: (UUID?) -> Void
    let onDeleteLastMessage: () -> Void
    let onDelete: () -> Void
    let onCancelRename: () -> Void
    let onInfo: () -> Void
    let onEditTags: () -> Void
    let onStopRuntime: () -> Void

    @FocusState private var focused: Bool
    @State private var showsUsageAnalytics = false

    var body: some View {
        SessionRowCard(isCurrent: isCurrent) {
            if isEditing {
                editingBody
            } else {
                normalBody
            }
        }
        .contextMenu {
            contextMenuContent
        }
        .sheet(isPresented: $showsUsageAnalytics) {
            NavigationStack {
                SessionUsageAnalyticsView(sessionID: session.id, sessionName: session.name)
            }
        }
    }

    private var normalBody: some View {
        SessionListRowContentBody(
            title: session.name,
            subtitle: primarySubtitle,
            footnote: secondarySubtitle,
            tags: tags,
            isCurrent: isCurrent,
            isRunning: isRunning,
            runtimeStatus: runtimeState?.runStatus
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
    }

    private var editingBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(NSLocalizedString("会话名称", comment: ""), text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { commit() }
                .onAppear { focused = true }

            HStack(spacing: 8) {
                Button(NSLocalizedString("保存", comment: "")) {
                    commit()
                }
                .buttonStyle(.borderedProminent)

                Button(NSLocalizedString("取消", comment: "")) {
                    onCancelRename()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        Button {
            showsUsageAnalytics = true
        } label: {
            Label(NSLocalizedString("session_usage.title", value: "Conversation Analytics", comment: "会话分析统计入口"), systemImage: "chart.bar.xaxis")
        }

        Button {
            onSelect()
        } label: {
            Label(NSLocalizedString("切换到此会话", comment: ""), systemImage: "checkmark.circle")
        }

        Button {
            onRename()
        } label: {
            Label(NSLocalizedString("重命名", comment: ""), systemImage: "pencil")
        }

        Menu {
            Button {
                onMoveToFolder(nil)
            } label: {
                Label(
                    NSLocalizedString("未分类", comment: ""),
                    systemImage: currentFolderID == nil ? "checkmark" : "tray"
                )
            }

            ForEach(moveOptions) { option in
                Button {
                    onMoveToFolder(option.id)
                } label: {
                    Label(option.title, systemImage: currentFolderID == option.id ? "checkmark" : "folder")
                }
            }
        } label: {
            Label(NSLocalizedString("移动到文件夹", comment: ""), systemImage: "folder")
        }

        Button {
            onBranch(false)
        } label: {
            Label(NSLocalizedString("创建提示词分支", comment: ""), systemImage: "arrow.branch")
        }

        Button {
            onBranch(true)
        } label: {
            Label(NSLocalizedString("复制历史创建分支", comment: ""), systemImage: "arrow.triangle.branch")
        }

        Button {
            onDeleteLastMessage()
        } label: {
            Label(NSLocalizedString("删除最后一条消息", comment: ""), systemImage: "delete.backward")
        }

        Button {
            onInfo()
        } label: {
            Label(NSLocalizedString("查看会话信息", comment: ""), systemImage: "info.circle")
        }

        if isRunning {
            Button(role: .destructive) {
                onStopRuntime()
            } label: {
                Label(NSLocalizedString("停止运行", comment: "Stop conversation runtime"), systemImage: "stop.circle")
            }
        }

        Divider()

        Button {
            onEditTags()
        } label: {
            Label("\(NSLocalizedString("标签", comment: "Session tags action"))...", systemImage: "tag")
        }

        Divider()

        Button(role: .destructive) {
            onDelete()
        } label: {
            Label(NSLocalizedString("删除会话", comment: ""), systemImage: "trash")
        }
    }

    private func commit() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
    }

    private var primarySubtitle: String? {
        if let searchSummary, !searchSummary.isEmpty {
            return searchSummary
        }
        return locationSummary
    }

    private var secondarySubtitle: String? {
        if let runtimeSummary {
            return runtimeSummary
        }
        guard searchSummary == nil || searchSummary?.isEmpty == true else {
            return locationSummary
        }
        return nil
    }

    private var runtimeSummary: String? {
        guard let runtimeState else { return nil }
        var parts: [String] = []
        if let origin = runtimeState.origin {
            parts.append(String(
                format: NSLocalizedString("由“%@”创建", comment: "Conversation origin summary"),
                origin.parentSessionNameSnapshot
            ))
        }
        if let status = runtimeState.runStatus,
           let label = Self.sessionListStatusLabel(for: status) {
            parts.append(label)
        }
        if runtimeState.pendingEventCount > 0 {
            parts.append(String(
                format: NSLocalizedString("%d 条待处理", comment: "Pending conversation event count"),
                runtimeState.pendingEventCount
            ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// 会话列表只承担进行中活动的总览；终态详情保留在对应消息与运行记录中。
    static func sessionListStatusLabel(for status: ConversationRunStatus) -> String? {
        switch status {
        case .queued: return NSLocalizedString("排队中", comment: "Conversation run queued")
        case .running, .waitingTool: return NSLocalizedString("生成中", comment: "Conversation run running")
        case .waitingConversation: return NSLocalizedString("等待会话", comment: "Conversation run waiting for conversation")
        case .waitingUser: return NSLocalizedString("等待用户", comment: "Conversation run waiting for user")
        case .pausedByBudget: return NSLocalizedString("已暂停", comment: "Conversation run paused by budget")
        case .completed, .failed, .cancelled, .interrupted: return nil
        }
    }
}

// MARK: - 行文本主体（标题 + 副信息 + 状态徽标）

/// 卡片内部的文本结构，独立于卡片外壳，便于复用。
struct SessionListRowContentBody: View {
    let title: String
    let subtitle: String?
    let footnote: String?
    let tags: [SessionTag]
    let isCurrent: Bool
    let isRunning: Bool
    let runtimeStatus: ConversationRunStatus?

    init(
        title: String,
        subtitle: String?,
        footnote: String?,
        tags: [SessionTag],
        isCurrent: Bool,
        isRunning: Bool,
        runtimeStatus: ConversationRunStatus? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.footnote = footnote
        self.tags = tags
        self.isCurrent = isCurrent
        self.isRunning = isRunning
        self.runtimeStatus = runtimeStatus
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .etFont(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(2)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .etFont(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let footnote, !footnote.isEmpty {
                    Text(footnote)
                        .etFont(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                SessionTagInlineList(tags: tags)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isRunning || runtimeStatus == .running || runtimeStatus == .waitingTool {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(NSLocalizedString("生成中", comment: ""))
                    .etFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
            }
        } else if let runtimeStatus,
                  runtimeStatus == .queued
                    || runtimeStatus == .waitingConversation
                    || runtimeStatus == .waitingUser
                    || runtimeStatus == .pausedByBudget {
            Image(systemName: runtimeStatus == .queued ? "clock" : "pause.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(runtimeStatus == .pausedByBudget ? Color.orange : Color.secondary)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}

struct SessionSearchResultRowContent: View {
    let title: String
    let preview: String
    let isCurrent: Bool
    let isRunning: Bool
    let titleColor: Color
    let previewColor: Color
    let selectedColor: Color

    init(
        title: String,
        preview: String,
        isCurrent: Bool,
        isRunning: Bool = false,
        titleColor: Color = .primary,
        previewColor: Color = .secondary,
        selectedColor: Color = .accentColor
    ) {
        self.title = title
        self.preview = preview
        self.isCurrent = isCurrent
        self.isRunning = isRunning
        self.titleColor = titleColor
        self.previewColor = previewColor
        self.selectedColor = selectedColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .etFont(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isCurrent ? selectedColor : titleColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(preview)
                    .etFont(.system(size: 12.5))
                    .foregroundStyle(previewColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingStatus
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var trailingStatus: some View {
        if isRunning {
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 6, height: 6)
                Text(NSLocalizedString("生成中", comment: ""))
                    .etFont(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.green)
            }
            .padding(.top, 1)
        } else if isCurrent {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selectedColor)
                .padding(.top, 1)
        }
    }
}

// MARK: - 会话信息 Sheet

struct SessionInfoPayload: Identifiable {
    let id = UUID()
    let session: ChatSession
    let messageCount: Int
    let isCurrent: Bool
    let onOpenSession: (UUID) -> Void
}

struct SessionInfoSheet: View {
    let payload: SessionInfoPayload
    @Environment(\.dismiss) private var dismiss
    @State private var sessionDraft: ChatSession

    init(payload: SessionInfoPayload) {
        self.payload = payload
        _sessionDraft = State(initialValue: payload.session)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(NSLocalizedString("会话概览", comment: "")) {
                    LabeledContent(NSLocalizedString("名称", comment: "")) {
                        TextField(NSLocalizedString("会话名称", comment: ""), text: $sessionDraft.name)
                    }
                    LabeledContent(NSLocalizedString("状态", comment: "")) {
                        Text(payload.isCurrent ? NSLocalizedString("当前会话", comment: "") : NSLocalizedString("历史会话", comment: ""))
                            .foregroundStyle(payload.isCurrent ? Color.accentColor : Color.secondary)
                    }
                    LabeledContent(NSLocalizedString("消息数量", comment: "")) {
                        Text(String(format: NSLocalizedString("%d 条", comment: ""), payload.messageCount))
                    }
                }

                Section(NSLocalizedString("首选模型", comment: "Preferred conversation model")) {
                    Picker(NSLocalizedString("首选模型", comment: "Preferred conversation model"), selection: preferredModelBinding) {
                        Text(NSLocalizedString("跟随全局模型", comment: "Follow global model"))
                            .tag("")
                        ForEach(ChatService.shared.activatedConversationModels, id: \.id) { model in
                            Text(model.model.displayName).tag(model.id)
                        }
                    }
                }

                Section(NSLocalizedString("唯一标识", comment: "")) {
                    Text(payload.session.id.uuidString)
                        .etFont(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(NSLocalizedString("会话信息", comment: ""))
            .guideSettingsPageContext(
                id: GuidePageID(rawValue: "session-editor-\(sessionDraft.id.uuidString)"),
                title: NSLocalizedString("会话信息", comment: ""),
                documents: [GuideDocumentReference(id: "settings-core", title: "Core Settings")],
                settings: [
                    .string("name", label: NSLocalizedString("会话名称", comment: ""), get: { sessionDraft.name }, set: { sessionDraft.name = $0 }),
                    .readOnly("preferred_model", label: NSLocalizedString("首选模型", comment: ""), value: { .string(sessionDraft.preferredModelIdentifier ?? "") }),
                    .readOnly("save_required", label: NSLocalizedString("修改后需要保存", comment: "向导保存说明"), value: { .bool(true) })
                ]
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("保存", comment: "")) {
                        ChatService.shared.updateSession(sessionDraft)
                        dismiss()
                    }
                    .disabled(sessionDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var preferredModelBinding: Binding<String> {
        Binding(
            get: { sessionDraft.preferredModelIdentifier ?? "" },
            set: { sessionDraft.preferredModelIdentifier = $0.isEmpty ? nil : $0 }
        )
    }

}
