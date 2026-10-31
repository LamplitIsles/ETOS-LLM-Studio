// ============================================================================
// UpdateTimelineView.swift
// ============================================================================
// ETOS LLM Studio iOS App
//
// 显示 Git 提交和检查更新。
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct UpdateTimelineView: View {
    @ObservedObject private var manager = UpdateTimelineManager.shared
    @ObservedObject private var appConfig = AppConfigStore.shared
    @Environment(\.openURL) private var openURL
    @State private var visibleTimelineLimit = 5
    @State private var linkedCommitNavigationTarget: LinkedUpdateTimelineCommit?
    @State private var showClearCacheConfirmation = false

    let highlightedCommit: UpdateTimelineCommit?

    init(highlightedCommit: UpdateTimelineCommit? = nil) {
        self.highlightedCommit = highlightedCommit
    }

    private let timelineInitialLimit = 5
    private let timelinePageSize = 20

    private var displayedCommits: [UpdateTimelineCommit] {
        manager.displayedCommits
    }

    private var visibleTimelineCommits: [UpdateTimelineCommit] {
        Array(displayedCommits.prefix(visibleTimelineLimit))
    }

    private var hasMoreTimelineCommits: Bool {
        visibleTimelineCommits.count < displayedCommits.count
    }

    var body: some View {
        List {
            if let highlightedCommit {
                linkedCommitSection(highlightedCommit)
            }
            timelineSection
            appStoreSection
            statusSection
            controlsSection
        }
        .navigationTitle(NSLocalizedString("检查更新", comment: "Update check navigation title"))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await manager.refresh(forceNetwork: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(manager.isRefreshing)
                .accessibilityLabel(NSLocalizedString("刷新检查更新", comment: ""))

                Button(role: .destructive) {
                    showClearCacheConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(manager.isRefreshing || manager.isSummarizing)
                .accessibilityLabel(NSLocalizedString("清空更新缓存", comment: "Clear update timeline cache"))
            }
        }
        .confirmationDialog(
            NSLocalizedString("清空更新缓存？", comment: "Clear update timeline cache confirmation title"),
            isPresented: $showClearCacheConfirmation,
            titleVisibility: .visible
        ) {
            Button(NSLocalizedString("清空更新缓存", comment: "Clear update timeline cache"), role: .destructive) {
                manager.clearPersistentCache()
                visibleTimelineLimit = timelineInitialLimit
            }
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("这会删除检查更新页面保存的 GitHub 时间线、限流状态和 AI 摘要缓存，下次刷新会重新请求。", comment: "Clear update timeline cache confirmation message"))
        }
        .task {
            await manager.refreshIfNeeded()
        }
        .onChange(of: displayedCommits.count) { _, newCount in
            if newCount <= timelineInitialLimit {
                visibleTimelineLimit = timelineInitialLimit
            } else {
                visibleTimelineLimit = min(max(visibleTimelineLimit, timelineInitialLimit), newCount)
            }
        }
        .navigationDestination(item: $linkedCommitNavigationTarget) { target in
            UpdateTimelineCommitDetailView(commit: target.commit)
        }
    }

    private func linkedCommitSection(_ commit: UpdateTimelineCommit) -> some View {
        Section {
            Button {
                linkedCommitNavigationTarget = LinkedUpdateTimelineCommit(commit: commit)
            } label: {
                UpdateTimelineRow(
                    commit: commit,
                    isFirst: true,
                    isLast: true
                )
            }
            .buttonStyle(.plain)
        } header: {
            Text(NSLocalizedString("关联 Commit", comment: "Linked update timeline commit section"))
        } footer: {
            Text(NSLocalizedString("来自反馈工单引用，点按可查看 Commit 详情。", comment: "Linked commit section footer"))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(NSLocalizedString("通道", comment: "Update timeline channel label")) {
                Text(manager.state.channel.displayName)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(NSLocalizedString("状态", comment: "Update timeline status label")) {
                Text(manager.state.status.displayName)
                    .foregroundStyle(statusColor)
            }
            if let currentBuild = manager.state.currentBuildNumber {
                LabeledContent(NSLocalizedString("当前 Build", comment: "Update timeline current build label"), value: "\(currentBuild)")
            }
            if let remoteBuild = manager.state.latestRemoteBuildNumber {
                LabeledContent(NSLocalizedString("推算最新 Build", comment: "Update timeline latest build label"), value: "\(remoteBuild)")
            }
            if let appStoreVersion = manager.state.appStoreVersion {
                LabeledContent(NSLocalizedString("App Store 版本", comment: "Update timeline app store version label"), value: appStoreVersion)
            }
            if let checkedAt = manager.state.lastCheckedAt {
                LabeledContent(NSLocalizedString("上次检查", comment: "Update timeline last checked label")) {
                    Text(checkedAt, style: .relative)
                        .foregroundStyle(.secondary)
                }
            }
            if let error = manager.state.lastErrorMessage, !error.isEmpty {
                Text(error)
                    .etFont(.footnote)
                    .foregroundStyle(.orange)
            }
            if let resetAt = manager.state.rateLimitResetAt {
                Text(String(format: NSLocalizedString("GitHub 限流可能会在 %@ 后恢复。", comment: "Update timeline rate limit footer"), resetAt.formatted(date: .omitted, time: .shortened)))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(NSLocalizedString("版本探针", comment: "Update timeline probe section"))
        }
    }

    private var controlsSection: some View {
        Section {
            Toggle(NSLocalizedString("自动检查更新", comment: "Update timeline auto check toggle"), isOn: autoCheckBinding)
        }
    }

    @ViewBuilder
    private var appStoreSection: some View {
        if !manager.state.allowsSummary, let appStoreURL = manager.state.appStoreURL {
            Section {
                Button {
                    openURL(appStoreURL)
                } label: {
                    Label(NSLocalizedString("前往 App Store 更新", comment: "Update timeline open App Store button"), systemImage: "arrow.up.circle")
                }
            }
        }
    }

    private var timelineSection: some View {
        Section {
            if displayedCommits.isEmpty {
                ContentUnavailableView(
                    NSLocalizedString("暂无时间线", comment: "Update timeline empty title"),
                    systemImage: "point.topleft.down.curvedto.point.bottomright.up",
                    description: Text(NSLocalizedString("刷新后会优先显示 GitHub 缓存中的提交记录。", comment: "Update timeline empty description"))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(Array(visibleTimelineCommits.enumerated()), id: \.element.id) { index, commit in
                    NavigationLink {
                        UpdateTimelineCommitDetailView(commit: commit)
                    } label: {
                        UpdateTimelineRow(
                            commit: commit,
                            isFirst: index == 0,
                            isLast: index == visibleTimelineCommits.count - 1
                        )
                    }
                }

                if hasMoreTimelineCommits {
                    Button {
                        visibleTimelineLimit = min(displayedCommits.count, visibleTimelineLimit + timelinePageSize)
                    } label: {
                        Label(NSLocalizedString("展开更多", comment: "Show more update timeline commits"), systemImage: "chevron.down.circle")
                    }
                }
            }
        } header: {
            Text(NSLocalizedString("Commit 时间线", comment: "Update timeline commits section"))
        }
    }

    private var autoCheckBinding: Binding<Bool> {
        Binding(
            get: { appConfig.updateTimelineAutoCheckEnabled },
            set: { newValue in
                appConfig.updateTimelineAutoCheckEnabled = newValue
                manager.autoCheckEnabled = newValue
            }
        )
    }

    private var statusColor: Color {
        switch manager.state.status {
        case .unknown:
            return .secondary
        case .current:
            return .green
        case .updateAvailable:
            return .blue
        }
    }


}

private struct LinkedUpdateTimelineCommit: Identifiable, Hashable {
    let commit: UpdateTimelineCommit
    var id: String { commit.id }
}

private struct UpdateTimelineRow: View {
    let commit: UpdateTimelineCommit
    let isFirst: Bool
    let isLast: Bool
    private let markerColumnWidth: CGFloat = 22
    private let markerDiameter: CGFloat = 9
    private let markerTopPadding: CGFloat = 5
    private let rowVerticalPadding: CGFloat = 6

    private var markerTopY: CGFloat {
        rowVerticalPadding + markerTopPadding
    }

    private var markerBottomY: CGFloat {
        markerTopY + markerDiameter
    }

    private var isBuildCommit: Bool {
        commit.inferredBuildNumber != nil
    }

    private var markerColor: Color {
        isBuildCommit ? .green : .accentColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(markerColor)
                .frame(width: markerDiameter, height: markerDiameter)
                .padding(.top, markerTopPadding)
                .frame(width: markerColumnWidth)

            VStack(alignment: .leading, spacing: 6) {
                Text(commit.shortOID)
                    .etFont(.caption.monospaced())
                    .foregroundStyle(isBuildCommit ? markerColor : Color.secondary)

                Text(commit.displayHeadline)
                    .etFont(.subheadline.weight(.semibold))
                    .foregroundStyle(isBuildCommit ? markerColor : Color.primary)
                    .lineLimit(2)

                if let date = commit.committedDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let build = commit.inferredBuildNumber {
                Text(String(format: NSLocalizedString("Build %d", comment: "Update timeline build badge"), build))
                    .etFont(.caption2.weight(.semibold))
                    .foregroundStyle(markerColor)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(markerColor.opacity(0.14), in: Capsule())
                    .accessibilityLabel(String(format: NSLocalizedString("Build %d", comment: "Update timeline build badge"), build))
            }
        }
        .padding(.vertical, rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            UpdateTimelineConnectorShape(
                isFirst: isFirst,
                isLast: isLast,
                markerTopY: markerTopY,
                markerBottomY: markerBottomY,
                lineTopExtension: 8,
                lineBottomExtension: 8
            )
            .stroke(markerColor.opacity(isBuildCommit ? 0.42 : 0.28), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: markerColumnWidth)
        }
    }
}

private struct UpdateTimelineConnectorShape: Shape {
    let isFirst: Bool
    let isLast: Bool
    let markerTopY: CGFloat
    let markerBottomY: CGFloat
    let lineTopExtension: CGFloat
    let lineBottomExtension: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.midX
        if !isFirst {
            path.move(to: CGPoint(x: x, y: rect.minY - lineTopExtension))
            path.addLine(to: CGPoint(x: x, y: rect.minY + markerTopY))
        }
        if !isLast {
            path.move(to: CGPoint(x: x, y: rect.minY + markerBottomY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY + lineBottomExtension))
        }
        return path
    }
}

struct UpdateTimelineCommitDetailView: View {
    @Environment(\.openURL) private var openURL
    let commit: UpdateTimelineCommit

    var body: some View {
        List {
            Section {
                LabeledContent(NSLocalizedString("Commit", comment: "Update timeline commit detail label"), value: commit.oid)
                if let build = commit.inferredBuildNumber {
                    LabeledContent(NSLocalizedString("推算 Build", comment: "Update timeline detail build label"), value: "\(build)")
                }
                if let date = commit.committedDate {
                    LabeledContent(NSLocalizedString("提交时间", comment: "Update timeline detail date label")) {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            Section(NSLocalizedString("Commit Message", comment: "Update timeline commit message section")) {
                FeedbackMarkdownView(content: commit.fullMessage)
                    .textSelection(.enabled)
            }

            if let url = commit.url {
                Section {
                    Button {
                        openURL(url)
                    } label: {
                        Label(NSLocalizedString("打开 GitHub Commit", comment: "Update timeline open GitHub commit"), systemImage: "safari")
                    }
                }
            }
        }
        .navigationTitle(commit.shortOID)
        .navigationBarTitleDisplayMode(.inline)
        .guideSettingsPageContext(
            id: GuidePageID(rawValue: "feedback-commit-\(commit.oid)"),
            title: NSLocalizedString("关联 Commit", comment: ""),
            documents: [GuideDocumentReference(id: "feedback-assistant", title: NSLocalizedString("反馈助手", comment: ""))],
            settings: [
                .readOnly("commit_sha", label: NSLocalizedString("Commit", comment: ""), value: { .string(commit.oid) })
            ]
        )
    }
}
