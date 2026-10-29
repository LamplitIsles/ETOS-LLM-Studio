// ============================================================================
// LocalDebugServerWebConsole.swift
// ============================================================================
// ETOS LLM Studio
//
// 本文件负责本地调试客户端的 Web 控制台数据编解码，
// 以及 providers 的同步命令。
// ============================================================================

import Combine
import Foundation

extension LocalDebugServer {
    nonisolated static func parseWebConsoleDate(_ value: String) -> Date? {
        let preciseFormatter = ISO8601DateFormatter()
        preciseFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let precise = preciseFormatter.date(from: value) {
            return precise
        }
        let defaultFormatter = ISO8601DateFormatter()
        defaultFormatter.formatOptions = [.withInternetDateTime]
        return defaultFormatter.date(from: value)
    }

    nonisolated static func formatWebConsoleDate(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    nonisolated func makeWebConsoleJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated func makeWebConsoleJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()

            if let timestamp = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: timestamp)
            }
            if let timestamp = try? container.decode(Int.self) {
                return Date(timeIntervalSince1970: TimeInterval(timestamp))
            }
            if let value = try? container.decode(String.self) {
                if let parsed = Self.parseWebConsoleDate(value) {
                    return parsed
                }
                if let timestamp = Double(value) {
                    return Date(timeIntervalSince1970: timestamp)
                }
            }

            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析日期")
        }
        return decoder
    }

    nonisolated func encodeWebConsoleJSONObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try makeWebConsoleJSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    nonisolated func decodeWebConsoleObject<T: Decodable>(_ raw: Any, as type: T.Type) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: raw)
        return try makeWebConsoleJSONDecoder().decode(type, from: data)
    }

    func handleProvidersList() async -> [String: Any] {
        await runDebugDataOperation { self.readDebugProviders() }
    }

    nonisolated private func readDebugProviders() -> [String: Any] {
        let providers = ConfigLoader.loadProviders()
        do {
            let payload = try encodeWebConsoleJSONObject(providers)
            return ["status": "ok", "providers": payload, "count": providers.count]
        } catch {
            return ["status": "error", "message": "提供商序列化失败：\(error.localizedDescription)"]
        }
    }

    func handleProvidersSave(_ json: [String: Any]) async -> [String: Any] {
        let request = LocalDebugJSONObject(value: json)
        return await runDebugDataOperation { self.replaceDebugProviders(request.value) }
    }

    nonisolated private func replaceDebugProviders(_ json: [String: Any]) -> [String: Any] {
        guard let providersRaw = json["providers"] else {
            return ["status": "error", "message": "缺少 providers 参数"]
        }

        do {
            let providers = try decodeWebConsoleObject(providersRaw, as: [Provider].self)
            let result = LocalDebugProviderStore.perform { current in
                current = providers
                return ["status": "ok", "message": "提供商配置已保存", "count": providers.count]
            }
            if result["status"] as? String == "ok" { ChatService.shared.reloadProviders() }
            return result
        } catch {
            return ["status": "error", "message": "保存提供商失败：\(error.localizedDescription)"]
        }
    }

}
