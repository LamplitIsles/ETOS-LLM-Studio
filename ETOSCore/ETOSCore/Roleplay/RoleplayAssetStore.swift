// ============================================================================
// RoleplayAssetStore.swift
// ============================================================================
// ETOS LLM Studio
//
// 管理 Character Card V3/CHARX 资源文件及其 HTML URI 映射。
// ============================================================================

import Foundation

public enum RoleplayAssetStore {
    private static var directory: URL {
        Persistence.getImageDirectory()
    }

    public static func resolvedURL(for asset: RoleplayCardAsset) -> URL? {
        guard let fileName = asset.localFileName else {
            return URL(string: asset.uri)
        }
        return directory.appendingPathComponent(fileName)
    }

    public static func replacingAssetURIs(in source: String, assets: [RoleplayCardAsset]) -> String {
        assets.reduce(source) { output, asset in
            guard let url = resolvedURL(for: asset), asset.localFileName != nil else { return output }
            let packagedPath: String?
            if asset.uri.hasPrefix("embeded://") {
                packagedPath = String(asset.uri.dropFirst("embeded://".count))
            } else if asset.uri.hasPrefix("__asset:") {
                packagedPath = String(asset.uri.dropFirst("__asset:".count))
            } else {
                packagedPath = nil
            }
            return [asset.uri, packagedPath.map { "embeded://\($0)" }, packagedPath.map { "__asset:\($0)" }]
                .compactMap { $0 }
                .reduce(output) { value, uri in
                    value.replacingOccurrences(of: uri, with: url.absoluteString)
                }
        }
    }

    public static func deleteFiles(for assets: [RoleplayCardAsset]) {
        for fileName in assets.compactMap(\.localFileName) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
        }
    }

}
