// ============================================================================
// ExtendedFeaturesView.swift
// ============================================================================
// ExtendedFeaturesView 界面 (iOS)
// - 负责该功能在 iOS 端的交互与展示
// - 遵循项目现有视图结构与状态流
// ============================================================================

import SwiftUI
import ETOSCore

struct ExtendedFeaturesView: View {
    @EnvironmentObject private var viewModel: ChatViewModel
    @ObservedObject private var achievementCenter = AchievementCenter.shared
    @State private var isShowingIntroDetails = false

    var body: some View {
        List {
            Section {
                settingsIntroCard(
                    title: NSLocalizedString("拓展功能", comment: "Extended features intro title"),
                    summary: NSLocalizedString("这里集中放置进阶能力、调试入口与跨平台工具集成。", comment: "Extended features intro summary"),
                    details: NSLocalizedString("拓展功能说明正文", comment: "Extended features intro details")
                        + "\n\n" + NSLocalizedString("batch.entry.description", value: "Open Batch Tasks to send independent requests together and retrieve results later. The provider must support the Batch API.", comment: "批量任务入口说明"),
                    isExpanded: $isShowingIntroDetails
                )
            }

            if achievementCenter.hasUnlockedAchievements {
                Section {
                    // 彩蛋入口只在已有记录后出现，避免提前暴露隐藏日记。
                    NavigationLink {
                        AchievementJournalView()
                    } label: {
                        SettingsListIconLabel("成就日记", icon: .achievementJournal)
                    }
                }
            }

            Section {
                NavigationLink {
                    SlashCommandSettingsView()
                } label: {
                    SettingsListIconLabel("快速指令", icon: .slashCommands)
                }
            } footer: {
                Text(NSLocalizedString("用简短命令快速打开聊天操作和设置页面。", comment: "Slash commands entry footer"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    BatchTasksView()
                } label: {
                    SettingsListIconLabel("batch.title", icon: .batch)
                }
                .accessibilityIdentifier("batch.tasks.entry")
            } footer: {
                Text(NSLocalizedString("batch.help.summary", value: "Send independent requests together and collect their results later.", comment: "批量介绍摘要"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    BackgroundGenerationSettingsView()
                } label: {
                    SettingsListIconLabel("后台生成", icon: .backgroundGeneration)
                }
            } footer: {
                Text(NSLocalizedString("减少切换 App 后长回复中断。", comment: "后台生成入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    AppLockSettingsView()
                } label: {
                    SettingsListIconLabel("应用锁", icon: .security)
                }
            } footer: {
                Text(NSLocalizedString("保护本机界面与离线数据库文件。", comment: "应用锁入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    FeedbackCenterView()
                } label: {
                    SettingsListIconLabel("反馈助手", icon: .feedback)
                }
            } footer: {
                Text(NSLocalizedString("在 App 内提交并追踪反馈工单", comment: "反馈助手入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ImageGenerationFeatureView()
                        .environmentObject(viewModel)
                } label: {
                    SettingsListIconLabel("图片相册", icon: .imageGeneration)
                }
            } footer: {
                Text(NSLocalizedString("查看当前会话中助手返回的图片。", comment: "图片相册入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    LocalDebugView()
                } label: {
                    SettingsListIconLabel("远程文件访问", icon: .remoteFiles)
                }
            } footer: {
                Text(NSLocalizedString("通过局域网远程访问和管理 Documents 目录，方便命令行工具操作。", comment: "远程文件访问入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    StorageManagementView()
                } label: {
                    SettingsListIconLabel("存储管理", icon: .storage)
                }
            } footer: {
                Text(NSLocalizedString("管理本地模型、文件与缓存占用。", comment: "存储管理入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    ThirdPartyImportView()
                } label: {
                    SettingsListIconLabel("导入数据", icon: .importData)
                }
            } footer: {
                Text(NSLocalizedString("支持导入 ETOS 数据包，也可从 Cherry Studio 等来源迁移。", comment: "导入数据入口说明"))
                    .etFont(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    NetworkConnectionSecuritySettingsView()
                } label: {
                    Label(NSLocalizedString("Connection Exceptions", comment: "连接例外页面标题"), systemImage: "network")
                }
            }
        }
        .navigationTitle(NSLocalizedString("拓展功能", comment: "拓展功能页标题"))
        .listStyle(.insetGrouped)
        .guideSettingsPageContext(
            id: "settings-extended-features",
            title: NSLocalizedString("拓展功能", comment: "拓展功能向导上下文标题"),
            documents: [GuideDocumentReference(id: "settings-extended", title: "Extended Features")] + BatchGuideSupport.documents,
            isActive: !isShowingIntroDetails,
            settings: [
                .readOnly("available_sections", label: NSLocalizedString("可用功能入口", comment: "向导设置字段"), value: {
                    .array([
                        "slash_commands", "batch_tasks", "background_generation", "app_lock", "feedback", "local_models",
                        "image_gallery", "remote_files", "storage", "data_import", "connection_exceptions"
                    ].map(JSONValue.string))
                })
            ]
        )
    }

    private func settingsIntroCard(
        title: String,
        summary: String,
        details: String,
        isExpanded: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(title, comment: "设置介绍卡片标题"))
                .etFont(.headline.weight(.semibold))
            Text(NSLocalizedString(summary, comment: "设置介绍卡片摘要"))
                .etFont(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                isExpanded.wrappedValue = true
            } label: {
                Text(NSLocalizedString("进一步了解…", comment: "设置介绍卡片展开按钮"))
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
                    Text(NSLocalizedString(details, comment: "设置介绍卡片详情"))
                        .etFont(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(NSLocalizedString(title, comment: "设置介绍卡片详情标题"))
                .navigationBarTitleDisplayMode(.inline)
                .guideSettingsPageContext(
                    id: "settings-extended-introduction", title: title,
                    documents: [GuideDocumentReference(id: "settings-extended", title: "Extended Features")] + BatchGuideSupport.documents,
                    settings: [.readOnly("read_only", label: NSLocalizedString("使用说明", comment: ""), value: { .bool(true) })]
                )
            }
        }
    }
}
