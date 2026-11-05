import Foundation
import Testing
@testable import ETOSCore

@MainActor
@Suite("软件键盘 Return 配置")
struct SoftwareKeyboardReturnConfigTests {
    @Test("默认发送，独立于硬件键盘并参与同步")
    func defaultsAndIsolation() throws {
        let software = AppConfigKey.iOSSoftwareKeyboardReturnSendsMessage
        let hardware = AppConfigKey.iOSHardwareKeyboardReturnSendsMessage
        #expect(software.rawValue == "chat.composer.softwareKeyboard.returnSendsMessage.iOS")
        #expect(software.rawValue != hardware.rawValue)
        #expect(software.defaultValue == .bool(true))
        #expect(software.participatesInSync)
        #expect(!hardware.participatesInSync)

        let suiteName = "SoftwareKeyboardReturn-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let initial = AppConfigStore.initialValues(userDefaults: defaults)
        #expect(initial[software] == .bool(true))
        #expect(initial[hardware] == .bool(true))
        defaults.set(false, forKey: software.rawValue)
        let changed = AppConfigStore.initialValues(userDefaults: defaults)
        #expect(changed[software] == .bool(false))
        #expect(changed[hardware] == .bool(true))
        defaults.set(false, forKey: hardware.rawValue)
        defaults.set(true, forKey: software.rawValue)
        let reversed = AppConfigStore.initialValues(userDefaults: defaults)
        #expect(reversed[software] == .bool(true))
        #expect(reversed[hardware] == .bool(false))
    }

    @Test("测试快照往返保留软件键盘设置，不访问应用数据库")
    func snapshotRoundTrip() throws {
        let software = AppConfigKey.iOSSoftwareKeyboardReturnSendsMessage
        let hardware = AppConfigKey.iOSHardwareKeyboardReturnSendsMessage
        for value in [false, true] {
            let cache = AppConfigSnapshotCache(values: [software.rawValue: value, hardware.rawValue: !value])
            let syncSnapshot = cache.snapshot(includeLocalOnly: false)
            #expect(syncSnapshot[hardware.rawValue] == nil)
            #expect(syncSnapshot[software.rawValue] as? Bool == value)
            let serialized = try JSONSerialization.data(withJSONObject: syncSnapshot)
            let restored = try #require(JSONSerialization.jsonObject(with: serialized) as? [String: Any])
            let raw = try #require(restored[software.rawValue])
            #expect(AppConfigStore.appConfigValue(from: raw, for: software) == .bool(value))
            #expect(cache.snapshot(includeLocalOnly: true)[hardware.rawValue] as? Bool == !value)
        }
    }
}
