// ============================================================================
// SystemEntryInboxPreview.swift
// ETOS LLM Studio iOS App
// ============================================================================

import SwiftUI
import ETOSCore

extension Notification.Name {
    static let requestSystemEntryInboxPreview = Notification.Name("ios.requestSystemEntryInboxPreview")
}

struct SystemEntryInboxPayload: Identifiable, Sendable {
    let id: UUID
    let request: ETOSInboxRequest
}

enum SystemEntryInboxLoader {
    nonisolated static func load(requestID: UUID) throws -> SystemEntryInboxPayload {
        guard let layout = ETOSSharedStorageLayout.resolve() else { throw CocoaError(.fileNoSuchFile) }
        let request = try ETOSInboxStore.load(requestID: requestID, layout: layout)
        return SystemEntryInboxPayload(id: requestID, request: request)
    }
}

struct SystemEntryInboxPreviewView: View {
    let payload: SystemEntryInboxPayload
    let onComplete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(payload.request.items) { item in
                        Label(item.displayName, systemImage: icon(for: item.kind))
                    }
                } header: {
                    Text(NSLocalizedString("内容", comment: "Inbox preview content"))
                } footer: {
                    Text(NSLocalizedString("分享的内容暂时无法发送到聊天。", comment: "Share submission is unavailable"))
                }
            }
            .navigationTitle(NSLocalizedString("预览", comment: "Inbox preview title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("取消", comment: "Cancel inbox preview")) { onComplete() }
                }
            }
        }
    }

    private func icon(for kind: ETOSInboxItemKind) -> String {
        switch kind {
        case .text: return "text.alignleft"
        case .url: return "link"
        case .image: return "photo"
        case .audio: return "waveform"
        case .file: return "doc"
        }
    }
}

enum SystemEntryURLRouter {
    @MainActor
    static func handle(_ url: URL) async -> Bool {
        guard url.scheme?.lowercased() == ETOSSystemEntryConstants.appURLScheme else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "inbox":
            guard let rawID = components.first, let requestID = UUID(uuidString: rawID) else { return true }
            do {
                let payload = try await Task.detached(priority: .userInitiated) {
                    try SystemEntryInboxLoader.load(requestID: requestID)
                }.value
                NotificationCenter.default.post(name: .requestSystemEntryInboxPreview, object: payload)
            } catch {
                NotificationCenter.default.post(name: .newAPIProviderImportDidFail, object: error.localizedDescription)
            }
            return true
        case "open":
            guard let destination = components.first else { return false }
            if destination == "app" {
                // Web Clip 只需将 App 带到前台，保留用户上次停留的界面即可。
                return true
            }
            return true
        default:
            return false
        }
    }
}
