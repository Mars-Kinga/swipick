import Foundation
import SwiftData
import Testing
@testable import Zeying

@MainActor
struct SuggestedReviewTests {
    @Test("推荐计数在英文中正确处理多个参数与单复数")
    func suggestionCountsUseEnglishPluralRules() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let locale = Locale(identifier: "en")
        let one = 1, two = 2
        #expect(String(localized: "\(one) 组建议 · \(two) 张照片", bundle: bundle, locale: locale) == "1 suggested group · 2 photos")
        #expect(String(localized: "\(two) 组建议 · \(one) 张照片", bundle: bundle, locale: locale) == "2 suggested groups · 1 photo")
        let title = "Similar Versions"
        #expect(String(localized: "\(title) · \(one) 张", bundle: bundle, locale: locale) == "Similar Versions · 1 photo")
    }

    @Test("整组决定只需一次撤销，恢复原来的收藏待办与未审核状态")
    func groupUndoRestoresEveryDecision() throws {
        let suite = "suggestion-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext, defaults: defaults)
        #expect(store.stageFavorite(for: "favorite", alreadyFavorite: false))
        let priorToken = store.latestUndoToken
        #expect(store.decideGroup(["favorite", "a", "b", "a"], keeping: ["a"]))
        #expect(store.decision(for: "favorite") == .keep)
        #expect(store.isPendingFavorite("favorite"))
        #expect(store.decision(for: "b") == .delete)
        let token = try #require(store.latestUndoToken)
        #expect(store.undo(matching: token))
        #expect(store.latestUndoToken == priorToken)
        #expect(store.decision(for: "a") == nil)
        #expect(store.decision(for: "b") == nil)
        #expect(store.isPendingFavorite("favorite"))
        let reopened = ReviewStore(context: container.mainContext, defaults: defaults)
        #expect(reopened.decision(for: "b") == nil)
    }

    @Test("空选择或无效保留项不能产生整组删除")
    func invalidSelectionDoesNotMutate() throws {
        let container = try ModelContainer(for: ReviewRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = ReviewStore(context: container.mainContext)
        #expect(!store.decideGroup(["a", "b"], keeping: []))
        #expect(!store.decideGroup(["a", "b"], keeping: ["missing"]))
        #expect(store.decision(for: "a") == nil)
        #expect(!store.canUndo)
    }

    @Test("跳过建议独立持久化，恢复建议不改变审核记录")
    func skippedSuggestionsPersistIndependently() throws {
        let suite = "skipped-suggestions-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = CleanupSuggestion(id: "group", kind: .similar, reason: .possibleVersions, assetIDs: ["a", "b"],
                                      recommendedKeepID: nil, protectedIDs: [], knownBytes: nil, newestDate: nil)
        let service = PhotoSuggestionService(defaults: defaults)
        service.skip(group)
        service.rememberSession([group], index: 0)
        let reopened = PhotoSuggestionService(defaults: defaults)
        #expect(reopened.skippedIDs == ["group"])
        #expect(reopened.resumeGroupIDs == ["group"])
        reopened.restoreSkipped()
        #expect(PhotoSuggestionService(defaults: defaults).skippedIDs.isEmpty)
    }
}
