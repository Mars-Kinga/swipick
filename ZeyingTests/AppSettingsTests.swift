import Foundation
import Testing
@testable import Zeying

@MainActor
struct AppSettingsTests {
    @Test("触觉反馈默认开启并可跨实例保存")
    func hapticsPreferencePersists() throws {
        let suiteName = "ZeyingTests.AppSettings.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.hapticsEnabled)

        settings.hapticsEnabled = false
        let reopened = AppSettings(defaults: defaults)
        #expect(!reopened.hapticsEnabled)

        reopened.hapticsEnabled = true
        #expect(AppSettings(defaults: defaults).hapticsEnabled)
    }

    @Test("移除旧版逐张删除设置")
    func retiredDirectDeletePreferenceIsCleared() throws {
        let suiteName = "ZeyingTests.AppSettings.DirectDelete.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "com.mars.zeying.directDeleteEnabled")
        _ = AppSettings(defaults: defaults)
        #expect(defaults.object(forKey: "com.mars.zeying.directDeleteEnabled") == nil)
    }
}
