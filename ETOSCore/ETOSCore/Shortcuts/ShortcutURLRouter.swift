// ============================================================================
// ShortcutURLRouter.swift
// ============================================================================
// 自定义 URL Scheme 路由
// ============================================================================

import Foundation

private enum ShortcutURLRoute: String, Sendable {
    case importRoute = "import"
    case callback = "callback"
    case templateStatus = "template-status"
}

@MainActor
public final class ShortcutURLRouter {
    public static let shared = ShortcutURLRouter()
    nonisolated public static let appScheme = "etosllmstudio"

    private init() {}

    @discardableResult
    public func handleIncomingURL(_ url: URL) async -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == Self.appScheme else {
            return false
        }
        guard let route = Self.resolveRoute(from: url) else {
            return false
        }

        let normalizedURL = Self.normalizedShortcutURL(for: route, original: url)
        switch route {
        case .importRoute:
            _ = await ShortcutToolManager.shared.importFromClipboard(triggerURL: normalizedURL)
            return true
        case .callback:
            return ShortcutToolManager.shared.handleCallbackURL(normalizedURL)
        case .templateStatus:
            return ShortcutToolManager.shared.handleOfficialTemplateStatusURL(normalizedURL)
        }
    }

    public nonisolated static func normalizedCompletionURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == appScheme,
              let route = resolveRoute(from: url), route != .importRoute else { return nil }
        return normalizedShortcutURL(for: route, original: url)
    }

    private nonisolated static func resolveRoute(from url: URL) -> ShortcutURLRoute? {
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathComponents = url.path
            .split(separator: "/")
            .map { $0.lowercased() }
        let acceptedShortcutHosts: Set<String> = ["shortcut", "shortcuts"]

        if let host, acceptedShortcutHosts.contains(host) {
            return pathComponents.first.flatMap(ShortcutURLRoute.init(rawValue:))
        }

        if host == nil || host?.isEmpty == true {
            guard pathComponents.count >= 2,
                  acceptedShortcutHosts.contains(pathComponents[0]) else {
                return nil
            }
            return ShortcutURLRoute(rawValue: pathComponents[1])
        }

        if let host, pathComponents.isEmpty {
            return ShortcutURLRoute(rawValue: host)
        }

        return nil
    }

    private nonisolated static func normalizedShortcutURL(for route: ShortcutURLRoute, original url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.host = "shortcuts"
        components.path = "/\(route.rawValue)"
        return components.url ?? url
    }
}

public extension Notification.Name {
    static let newAPIProviderImportDidFail = Notification.Name("newAPIProviderImportDidFail")
}

public enum NewAPIProviderImportURLHandler {
    public static func canHandle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ShortcutURLRouter.appScheme else {
            return false
        }
        let parts = routeParts(from: url)
        return parts == ["provider", "install"]
            || parts == ["provider", "add"]
            || parts == ["providers", "api-keys"]
            || parts == ["providers", "install"]
    }

    private static func routeParts(from url: URL) -> [String] {
        var parts: [String] = []
        if let host = url.host?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            parts.append(host)
        }
        parts.append(contentsOf: url.path
            .split(separator: "/")
            .map { $0.lowercased() }
        )
        return parts
    }

}
