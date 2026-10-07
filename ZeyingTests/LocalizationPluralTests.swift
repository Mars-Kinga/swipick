import Foundation
import Testing
@testable import Zeying

struct LocalizationPluralTests {
    @Test("中英文计数使用正确单复数", arguments: [1, 2])
    func countersUseLanguageAppropriateForms(_ count: Int) throws {
        let english = try languageBundle("en")
        let chinese = try languageBundle("zh-Hans")
        let englishLocale = Locale(identifier: "en")
        let chineseLocale = Locale(identifier: "zh-Hans")
        #expect(String(localized: "\(count) 项", bundle: english, locale: englishLocale) == "\(count) \(count == 1 ? "item" : "items")")
        #expect(String(localized: "\(count) 张照片", bundle: english, locale: englishLocale) == "\(count) \(count == 1 ? "photo" : "photos")")
        #expect(String(localized: "\(count) 个", bundle: english, locale: englishLocale) == "\(count) \(count == 1 ? "video" : "videos")")
        #expect(String(localized: "\(count) 项", bundle: chinese, locale: chineseLocale) == "\(count) 项")
        let title = "April"
        #expect(String(localized: "\(title) · 剩余 \(count) 项", bundle: english, locale: englishLocale)
            == "April · \(count) \(count == 1 ? "item" : "items") left")
        let bytes = "1 MB"
        #expect(String(localized: "查看清理统计，已清理 \(count) 张照片、\(count) 个视频，Live 转静态 \(count) 张，已知资源大小 \(bytes)", bundle: english, locale: englishLocale)
            == "Cleanup totals: \(count) \(count == 1 ? "photo" : "photos") and \(count) \(count == 1 ? "video" : "videos") deleted; \(count) \(count == 1 ? "Live Photo" : "Live Photos") converted to stills; 1 MB of known resource sizes.")
        #expect(String(localized: "查看清理统计，已清理 \(count) 张照片、\(count) 个视频，Live 转静态 \(count) 张，已知资源大小 \(bytes)", bundle: chinese, locale: chineseLocale)
            == "查看清理统计，已清理 \(count) 张照片、\(count) 个视频，Live 转静态 \(count) 张，已知资源大小 1 MB")
        if Bundle.main.preferredLocalizations.first == "en" {
            #expect(String(localized: "\(count) 项") == "\(count) \(count == 1 ? "item" : "items")")
        } else if Bundle.main.preferredLocalizations.first == "zh-Hans" {
            #expect(String(localized: "\(count) 项") == "\(count) 项")
        }
    }

    private func languageBundle(_ language: String) throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }
}
