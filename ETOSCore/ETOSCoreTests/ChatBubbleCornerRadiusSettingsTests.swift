import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("聊天气泡圆角配置")
struct ChatBubbleCornerRadiusSettingsTests {
    @Test("缺失字段保持旧版外观并参与同步")
    func defaultsAndSync() throws {
        let key = AppConfigKey.chatBubbleCornerRadius
        #expect(key.rawValue == "chat.bubble.cornerRadius")
        #expect(key.defaultValue == .real(18))
        #expect(key.participatesInSync)
        #expect(ChatBubbleCornerRadiusSetting.minimum == 0)
        #expect(ChatBubbleCornerRadiusSetting.maximum == 36)
        #expect(ChatBubbleCornerRadiusSetting.step == 1)

        let suiteName = "ChatBubbleRadiusTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = AppConfigStore.initialValues(userDefaults: defaults)
        #expect(initial[key] == .real(18))
        let snapshot = AppConfigStore.snapshot(from: initial, includeLocalOnly: false)
        #expect(snapshot[key.rawValue] as? Double == 18)
    }

    @Test("写入、恢复和初始值按同一范围和步长规范化")
    func normalizationAtIngress() throws {
        let key = AppConfigKey.chatBubbleCornerRadius
        let samples: [(Double, Double)] = [
            (-100, 0), (0, 0), (0.49, 0), (0.5, 1), (17.6, 18),
            (18, 18), (35.5, 36), (36, 36), (100, 36),
            (.nan, 18), (.infinity, 18), (-.infinity, 18)
        ]
        for (input, expected) in samples {
            #expect(ChatBubbleCornerRadiusSetting.normalized(input) == expected)
            #expect(AppConfigStore.normalizedAppConfigValue(.real(input), for: key) == .real(expected))
            #expect(AppConfigStore.appConfigValue(from: input, for: key) == .real(expected))
        }
        #expect(AppConfigStore.appConfigValue(from: "invalid", for: key) == nil)

        let suiteName = "ChatBubbleRadiusTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(38.8, forKey: key.rawValue)
        #expect(AppConfigStore.initialValues(userDefaults: defaults)[key] == .real(36))
        defaults.set("bad", forKey: key.rawValue)
        #expect(AppConfigStore.initialValues(userDefaults: defaults)[key] == .real(18))
    }

    @Test("测试快照保存并恢复圆角，不访问应用数据库")
    func snapshotRoundTrip() throws {
        let key = AppConfigKey.chatBubbleCornerRadius
        let cache = AppConfigSnapshotCache(values: [key.rawValue: 18.0])
        let changed = AppConfigStore.normalizedAppConfigValue(.real(22.6), for: key)
        cache.set(changed.anyValue, for: key)
        let snapshot = cache.snapshot(includeLocalOnly: false)
        let encoded = try JSONSerialization.data(withJSONObject: snapshot)
        let restored = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let value = try #require(restored[key.rawValue])
        #expect(AppConfigStore.appConfigValue(from: value, for: key) == .real(23))
        #expect(AppConfigStore.appConfigValue(from: 200.0, for: key) == .real(36))
    }
}
