// ============================================================================
// StorageManagementView.swift
// ============================================================================
// ETOS LLM Studio iOS App - 存储管理视图
//
// 功能特性:
// - 显示 Documents 目录的存储使用概览
// - 按类别浏览文件
// - 提供缓存清理功能
// ============================================================================

import SwiftUI
import ETOSCore

struct StorageManagementView: View {
    @State private var storageBreakdown = StorageBreakdown()
    @State private var isLoading = true
    @State private var showClearCacheAlert = false
    @State private var cleanupResult: CleanupResult?
    
    struct CleanupResult: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    var body: some View {
        List {
            // 存储概览
            storageOverviewSection
            
            // 按类别浏览
            storageCategoriesSection
            
            // 清理工具
            cleanupToolsSection

            // 与本地 Linux 共用授权的外部文件夹
            ExternalStorageMountSection()
        }
        .navigationTitle(NSLocalizedString("存储管理", comment: ""))
        .guideSettingsPageContext(
            id: "settings-storage-management",
            title: NSLocalizedString("存储管理", comment: "存储管理向导上下文标题"),
            documents: [GuideDocumentReference(id: "storage-management", title: "Storage Management")],
            settings: [
                .readOnly("loading", label: NSLocalizedString("正在统计", comment: "向导设置字段"), value: { .bool(isLoading) }),
                .readOnly("total_bytes", label: NSLocalizedString("总使用空间", comment: "向导设置字段"), value: { .int(Int(clamping: storageBreakdown.totalSize)) }),
                .readOnly("cache_bytes", label: NSLocalizedString("缓存", comment: "向导设置字段"), value: { .int(Int(clamping: storageBreakdown.cacheSize)) }),
                .readOnly("other_bytes", label: NSLocalizedString("其他文件", comment: "向导设置字段"), value: { .int(Int(clamping: storageBreakdown.otherSize)) }),
                .readOnly("categories", label: NSLocalizedString("存储分类", comment: "向导设置字段"), value: {
                    .array(StorageCategory.allCases.map { category in
                        .dictionary([
                            "id": .string(category.rawValue),
                            "name": .string(category.displayName),
                            "bytes": .int(Int(clamping: storageBreakdown.categorySize[category] ?? 0))
                        ])
                    })
                })
            ]
        )
        .refreshable {
            await refreshData()
        }
        .task {
            await refreshData()
        }
        .alert(NSLocalizedString("清理缓存", comment: ""), isPresented: $showClearCacheAlert) {
            Button(NSLocalizedString("取消", comment: ""), role: .cancel) {}
            Button(NSLocalizedString("清理", comment: ""), role: .destructive) {
                performCacheCleanup()
            }
        } message: {
            Text(NSLocalizedString("将删除所有语音和图片缓存文件。此操作不可撤销。", comment: ""))
        }
        .alert(item: $cleanupResult) { result in
            Alert(
                title: Text(result.title),
                message: Text(result.message),
                dismissButton: .default(Text(NSLocalizedString("好的", comment: "")))
            )
        }
    }
    
    // MARK: - 存储概览
    
    private var storageOverviewSection: some View {
        Section {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else {
                VStack(alignment: .center, spacing: 12) {
                    Image(systemName: "internaldrive")
                        .etFont(.system(size: 40))
                        .foregroundStyle(.blue)
                    
                    VStack(spacing: 4) {
                        Text(NSLocalizedString("总使用空间", comment: ""))
                            .etFont(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(StorageUtility.formatSize(storageBreakdown.totalSize))
                            .etFont(.title.weight(.bold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
        }
    }
    
    // MARK: - 存储类别
    
    private var storageCategoriesSection: some View {
        Section {
            NavigationLink {
                DocumentsStorageBrowserView()
            } label: {
                DocumentsStorageRow(
                    name: StorageUtility.documentsDirectory.lastPathComponent,
                    size: storageBreakdown.totalSize
                )
            }

            ForEach(StorageCategory.allCases) { category in
                NavigationLink {
                    FileListDetailView(category: category)
                } label: {
                    StorageCategoryRow(
                        category: category,
                        size: storageBreakdown.categorySize[category] ?? 0,
                        totalSize: storageBreakdown.totalSize
                    )
                }
            }
            
            // 其他文件
            if storageBreakdown.otherSize > 0 {
                NavigationLink {
                    OtherFilesView()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .etFont(.system(size: 18))
                            .foregroundStyle(.gray)
                            .frame(width: 32, height: 32)
                            .background(Color.gray.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("其他文件", comment: ""))
                                .etFont(.subheadline.weight(.medium))
                            Text(StorageUtility.formatSize(storageBreakdown.otherSize))
                                .etFont(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text(NSLocalizedString("存储分类", comment: ""))
        } footer: {
            Text(NSLocalizedString("点击类别可查看详细文件列表。", comment: ""))
                .etFont(.footnote)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - 清理工具
    
    private var cleanupToolsSection: some View {
        Section {
            // 清理缓存
            Button(role: .destructive) {
                showClearCacheAlert = true
            } label: {
                HStack {
                    Label(NSLocalizedString("清理所有缓存", comment: ""), systemImage: "trash")
                    Spacer()
                    Text(StorageUtility.formatSize(storageBreakdown.cacheSize))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(NSLocalizedString("清理工具", comment: ""))
        }
    }
    
    // MARK: - 操作方法
    
    private func refreshData() async {
        isLoading = true
        
        // 在后台线程计算存储信息
        let breakdown = await Task.detached(priority: .userInitiated) {
            StorageUtility.getStorageBreakdown()
        }.value
        
        await MainActor.run {
            storageBreakdown = breakdown
            isLoading = false
        }
    }
    
    private func performCacheCleanup() {
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                StorageUtility.clearCacheFiles()
            }.value
            
            await MainActor.run {
                cleanupResult = CleanupResult(
                    title: NSLocalizedString("清理完成", comment: ""),
                    message: String(format: NSLocalizedString("已删除 %d 个语音文件和 %d 个图片文件。", comment: ""), result.audioDeleted, result.imageDeleted)
                )
            }
            
            await refreshData()
        }
    }
}

// MARK: - 存储类别行

private struct StorageCategoryRow: View {
    let category: StorageCategory
    let size: Int64
    let totalSize: Int64
    
    private var percentage: Double {
        guard totalSize > 0 else { return 0 }
        return Double(size) / Double(totalSize)
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.systemImage)
                .etFont(.system(size: 18))
                .foregroundStyle(category.iconColor)
                .frame(width: 32, height: 32)
                .background(category.iconColor.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(category.displayName)
                    .etFont(.subheadline.weight(.medium))
                
                HStack(spacing: 8) {
                    Text(StorageUtility.formatSize(size))
                        .etFont(.caption)
                        .foregroundStyle(.secondary)
                    
                    if percentage > 0.01 {
                        Text(String(format: "%.1f%%", percentage * 100))
                            .etFont(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

private struct DocumentsStorageRow: View {
    let name: String
    let size: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .etFont(.system(size: 18))
                .foregroundStyle(.blue)
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .etFont(.subheadline.weight(.medium))
                Text(StorageUtility.formatSize(size))
                    .etFont(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 预览

#Preview {
    NavigationStack {
        StorageManagementView()
    }
}
