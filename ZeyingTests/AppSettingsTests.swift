import Foundation
import Testing
@testable import Zeying

@MainActor
struct AppSettingsTests {
    @Test("iCloud 自动下载默认关闭，并独立保存开启与关闭的选择")
    func iCloudAutoDownloadPreferencePersists() throws {
        let suiteName = "ZeyingTests.Settings.iCloud.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(!settings.iCloudAutoDownloadEnabled)
        settings.iCloudAutoDownloadEnabled = true
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.iCloudAutoDownloadEnabled)
        #expect(reopened.hapticsEnabled)
        #expect(reopened.protectFavoritesEnabled)
        #expect(!reopened.sideTapDecisionsEnabled)

        reopened.iCloudAutoDownloadEnabled = false
        #expect(!AppSettings(defaults: defaults).iCloudAutoDownloadEnabled)
    }

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

extension AppSettingsTests {
    @Test("照片点按默认关闭、收藏保护默认开启，并分别持久化")
    func safeInteractionPreferencesPersist() throws {
        let suite = "ZeyingTests.Settings.SafeInteraction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AppSettings(defaults: defaults)
        #expect(!first.sideTapDecisionsEnabled)
        #expect(first.protectFavoritesEnabled)
        first.sideTapDecisionsEnabled = true
        first.protectFavoritesEnabled = false
        first.hapticsEnabled = false
        let reopened = AppSettings(defaults: defaults)
        #expect(reopened.sideTapDecisionsEnabled)
        #expect(!reopened.protectFavoritesEnabled)
        #expect(!reopened.hapticsEnabled)
        reopened.sideTapDecisionsEnabled = false
        reopened.protectFavoritesEnabled = true
        let reset = AppSettings(defaults: defaults)
        #expect(!reset.sideTapDecisionsEnabled)
        #expect(reset.protectFavoritesEnabled)
        #expect(!reset.hapticsEnabled)
    }
}
