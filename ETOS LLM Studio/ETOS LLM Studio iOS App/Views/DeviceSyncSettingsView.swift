// ============================================================================
// DeviceSyncSettingsView.swift
// ============================================================================
// DeviceSyncSettingsView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import Foundation
import ETOSCore

struct DeviceSyncSettingsView: View {
    @EnvironmentObject private var cloudSyncManager: CloudSyncManager
    @ObservedObject private var appConfig = AppConfigStore.shared
    @State private var isSyncIntroExpanded = false
    @State private var pendingCloudOverwriteResolution: CloudSyncInitialResolution?
    @State private var pendingCloudConflictID: UUID?
    @State private var cloudOverwriteConfirmationText = ""
    @State private var isCloudOverwriteConfirmationPresented = false
    
    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("同步与备份", comment: "Sync and backup intro title"),
                    summary: NSLocalizedString("先区分手动快照、启动保护和设备同步，再选择要执行的操作。", comment: "Sync and backup intro summary"),
                    details: syncIntroDetails,
                    isExpanded: $isSyncIntroExpanded
                )
            }

            Section {
                NavigationLink {
                    BackupRestoreView()
                } label: {
                    Label(NSLocalizedString("数据库快照", comment: ""), systemImage: "externaldrive.badge.icloud")
                }
            } header: {
                Text(NSLocalizedString("手动快照", comment: ""))
            } footer: {
                Text(NSLocalizedString("手动导出或恢复 .elsbackup 快照。", comment: ""))
            }

            Section {
                Toggle(NSLocalizedString("启动时创建数据库备份点", comment: ""), isOn: $appConfig.syncBackupCreateOnLaunch)
            } header: {
                Text(NSLocalizedString("启动保护备份", comment: ""))
            } footer: {
                Text(NSLocalizedString("只保留一个本机启动还原点；新还原点确认可用后会删除上一份。", comment: ""))
            }

            Section {
                Toggle(NSLocalizedString("启用 iCloud 漫游同步", comment: ""), isOn: $appConfig.cloudSyncEnabled)

                Button {
                    Task {
                        await cloudSyncManager.performSync(options: .fullSync)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if isCloudSyncing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Label(NSLocalizedString("立即检查并同步", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                            .etFont(.headline)
                        Spacer()
                    }
                }
                .disabled(!appConfig.cloudSyncEnabled || isCloudSyncing)
            } header: {
                Text(NSLocalizedString("iCloud 漫游同步", comment: ""))
            } footer: {
                Text(NSLocalizedString("让同一 Apple ID 的设备自动同步数据。", comment: "iCloud 同步简短提示"))
            }

            Section(NSLocalizedString("iCloud 状态", comment: "")) {
                cloudSyncStatusView
            }
        }
        .navigationTitle(NSLocalizedString("同步与备份", comment: ""))
        .guideSettingsPageContext(
            id: "settings-sync",
            title: NSLocalizedString("同步与备份", comment: "同步设置向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-sync", title: "Sync and Backup")],
            settings: guideSettings
        )
        .confirmationDialog(
            NSLocalizedString("发现两套不同的数据", comment: ""),
            isPresented: Binding(
                get: { cloudSyncManager.initialConflict != nil },
                set: { if !$0 { cloudSyncManager.dismissInitialConflictPrompt() } }
            ),
            titleVisibility: .visible,
            presenting: cloudSyncManager.initialConflict
        ) { conflict in
            Button(NSLocalizedString("使用 iCloud 数据覆盖此设备", comment: ""), role: .destructive) {
                requestCloudOverwriteConfirmation(.useICloud, conflictID: conflict.id)
            }
            Button(NSLocalizedString("使用此设备数据覆盖 iCloud", comment: ""), role: .destructive) {
                requestCloudOverwriteConfirmation(.useThisDevice, conflictID: conflict.id)
            }
            Button(NSLocalizedString("暂不同步", comment: ""), role: .cancel) {
                cloudSyncManager.dismissInitialConflictPrompt()
            }
        } message: { conflict in
            Text(String(
                format: NSLocalizedString("此设备尚未建立可信的 iCloud 同步基线。本机有 %d 条记录，iCloud 有 %d 条记录；App 无法安全判断一端为空是首次接入还是有意删除。选择前不会修改任何数据，执行覆盖前会自动创建安全快照。", comment: ""),
                conflict.localRecordCount,
                conflict.iCloudRecordCount
            ))
        }
        .alert(cloudOverwriteConfirmationTitle, isPresented: $isCloudOverwriteConfirmationPresented) {
            TextField(NSLocalizedString("确认短语", comment: ""), text: $cloudOverwriteConfirmationText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {
                cancelCloudOverwriteConfirmation()
            }
            Button(NSLocalizedString("执行覆盖", comment: ""), role: .destructive) {
                executeCloudOverwrite()
            }
            .disabled(!isCloudOverwriteConfirmationValid)
        } message: {
            Text(cloudOverwriteConfirmationMessage)
        }
    }

    private var guideSettings: [GuidePageSetting] {
        [
            .bool("backup_on_launch", label: NSLocalizedString("启动时创建数据库备份点", comment: "向导设置字段"), get: { appConfig.syncBackupCreateOnLaunch }, set: { appConfig.syncBackupCreateOnLaunch = $0 }),
            .bool("icloud_sync_enabled", label: NSLocalizedString("启用 iCloud 漫游同步", comment: "向导设置字段"), get: { appConfig.cloudSyncEnabled }, set: { appConfig.cloudSyncEnabled = $0 })
        ]
    }

    private var syncIntroDetails: String {
        [
            NSLocalizedString("同步与备份说明正文", comment: ""),
            NSLocalizedString("库级覆盖 Skills 说明", comment: ""),
            NSLocalizedString("iCloud 首次同步裁决说明", comment: "")
        ].joined(separator: "\n\n")
    }

    private var requiredCloudOverwritePhrase: String {
        NSLocalizedString("确认覆盖", comment: "Cloud overwrite confirmation phrase")
    }

    private var isCloudOverwriteConfirmationValid: Bool {
        cloudOverwriteConfirmationText.trimmingCharacters(in: .whitespacesAndNewlines)
            == requiredCloudOverwritePhrase
    }

    private var cloudOverwriteConfirmationTitle: String {
        switch pendingCloudOverwriteResolution {
        case .useICloud:
            return NSLocalizedString("使用 iCloud 数据覆盖此设备", comment: "")
        case .useThisDevice:
            return NSLocalizedString("使用此设备数据覆盖 iCloud", comment: "")
        case nil:
            return NSLocalizedString("确认覆盖", comment: "")
        }
    }

    private var cloudOverwriteConfirmationMessage: String {
        let format: String
        switch pendingCloudOverwriteResolution {
        case .useICloud:
            format = NSLocalizedString("此操作会用 iCloud 的完整同步数据替换本机同步数据。请输入“%@”以确认覆盖；执行前会自动创建安全快照。", comment: "")
        case .useThisDevice:
            format = NSLocalizedString("此操作会删除 iCloud 当前同步记录并上传本机完整数据，其他设备随后会以本机数据为准。请输入“%@”以确认覆盖；执行前会自动创建安全快照。", comment: "")
        case nil:
            return ""
        }
        return String(format: format, requiredCloudOverwritePhrase)
    }

    private func requestCloudOverwriteConfirmation(_ resolution: CloudSyncInitialResolution, conflictID: UUID) {
        pendingCloudOverwriteResolution = resolution
        pendingCloudConflictID = conflictID
        cloudOverwriteConfirmationText = ""
        cloudSyncManager.dismissInitialConflictPrompt()
        Task { @MainActor in
            await Task.yield()
            guard pendingCloudOverwriteResolution != nil else { return }
            isCloudOverwriteConfirmationPresented = true
        }
    }

    private func cancelCloudOverwriteConfirmation() {
        pendingCloudOverwriteResolution = nil
        pendingCloudConflictID = nil
        cloudOverwriteConfirmationText = ""
        Task { @MainActor in
            await Task.yield()
            cloudSyncManager.restoreInitialConflictPrompt()
        }
    }

    private func executeCloudOverwrite() {
        guard isCloudOverwriteConfirmationValid,
              let conflictID = pendingCloudConflictID,
              let resolution = pendingCloudOverwriteResolution else { return }
        pendingCloudOverwriteResolution = nil
        pendingCloudConflictID = nil
        cloudOverwriteConfirmationText = ""
        Task {
            await cloudSyncManager.resolveInitialConflict(using: resolution, expectedConflictID: conflictID)
        }
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "同步与备份介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "同步与备份介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: ""))
                    .etFont(.footnote.weight(.medium))
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .sheet(isPresented: isExpanded) {
            NavigationStack {
                ScrollView {
                    Text(details)
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "同步与备份介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
    
    private var isCloudSyncing: Bool {
        if case .syncing = cloudSyncManager.state {
            return true
        }
        return false
    }

    @ViewBuilder
    private var cloudSyncStatusView: some View {
        if !appConfig.cloudSyncEnabled {
            Text(NSLocalizedString("iCloud 漫游同步已关闭", comment: ""))
                .etFont(.footnote)
                .foregroundColor(.secondary)
        } else {
            switch cloudSyncManager.state {
            case .idle:
                Text(NSLocalizedString("未进行同步", comment: "")).etFont(.footnote).foregroundColor(.secondary)
            case .syncing(let message):
                HStack {
                    ProgressView()
                    Text(message).etFont(.footnote)
                }
            case .waitingForInitialDecision:
                Label(NSLocalizedString("等待选择数据来源", comment: ""), systemImage: "arrow.triangle.branch")
                    .etFont(.footnote)
                    .foregroundStyle(.orange)
            case .success(let summary):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("同步成功", comment: ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text(summaryDescription(summary))
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                    if let lastUpdated = cloudSyncManager.lastUpdatedAt {
                        Text(String(format: NSLocalizedString("上次同步：%@", comment: ""), lastUpdated.formatted(date: .abbreviated, time: .shortened)))
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 2) {
                    Label(NSLocalizedString("同步失败", comment: ""), systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                    Text(reason)
                        .etFont(.caption2)
                        .foregroundStyle(.secondary)
                }
            @unknown default:
                Text(NSLocalizedString("未知状态", comment: ""))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private func summaryDescription(_ summary: SyncMergeSummary) -> String {
        var parts: [String] = []
        if summary.importedProviders > 0 {
            parts.append(String(format: NSLocalizedString("提供商 +%d", comment: ""), summary.importedProviders))
        }
        if summary.importedBackgrounds > 0 {
            parts.append(String(format: NSLocalizedString("背景 +%d", comment: ""), summary.importedBackgrounds))
        }
        if summary.importedAudioFiles > 0 {
            parts.append(String(format: NSLocalizedString("音频 +%d", comment: ""), summary.importedAudioFiles))
        }
        if summary.importedImageFiles > 0 {
            parts.append(String(format: NSLocalizedString("图片 +%d", comment: ""), summary.importedImageFiles))
        }
        if summary.importedSkills > 0 {
            parts.append(String(format: NSLocalizedString("Skills +%d", comment: ""), summary.importedSkills))
        }
        if summary.importedShortcutTools > 0 {
            parts.append(String(format: NSLocalizedString("快捷指令工具 +%d", comment: ""), summary.importedShortcutTools))
        }
        if summary.importedFeedbackTickets > 0 {
            parts.append(String(format: NSLocalizedString("工单 +%d", comment: ""), summary.importedFeedbackTickets))
        }
        if summary.importedDailyPulseRuns > 0 {
            parts.append(String(format: NSLocalizedString("每日脉冲 +%d", comment: ""), summary.importedDailyPulseRuns))
        }
        if summary.importedUsageEvents > 0 {
            parts.append(String(format: NSLocalizedString("用量事件 +%d", comment: ""), summary.importedUsageEvents))
        }
        if summary.importedFontFiles > 0 {
            parts.append(String(format: NSLocalizedString("字体文件 +%d", comment: ""), summary.importedFontFiles))
        }
        if summary.importedFontRouteConfigurations > 0 {
            parts.append(String(format: NSLocalizedString("字体规则 +%d", comment: ""), summary.importedFontRouteConfigurations))
        }
        if summary.importedAppStorageValues > 0 {
            parts.append(String(format: NSLocalizedString("软件设置 +%d", comment: ""), summary.importedAppStorageValues))
        }
        let separator = NSLocalizedString("，", comment: "")
        return parts.isEmpty ? NSLocalizedString("两端数据一致", comment: "") : parts.joined(separator: separator)
    }

}
