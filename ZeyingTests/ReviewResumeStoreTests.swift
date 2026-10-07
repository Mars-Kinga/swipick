import Foundation
import Testing
@testable import Zeying

@MainActor
struct ReviewResumeStoreTests {
    @Test("上次处理的月份会在重新打开后恢复")
    func lastMonthPersists() throws {
        let suiteName = "ZeyingTests.ReviewResume.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 4, day: 19)))
        let first = ReviewResumeStore(defaults: defaults)
        first.rememberMonth(containing: date)

        let reopened = ReviewResumeStore(defaults: defaults)
        let remembered = try #require(reopened.lastMonth)
        #expect(Calendar.current.isDate(remembered, equalTo: date, toGranularity: .month))

        reopened.rememberMonth(containing: nil)
        #expect(reopened.lastMonth == remembered)
    }

    @Test("继续清理会记住类别和相簿入口")
    func reviewScopePersists() throws {
        let suiteName = "ZeyingTests.ReviewScope.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let date = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 2)))
        let first = ReviewResumeStore(defaults: defaults)
        first.remember(scope: .category(.screenshot), containing: date)

        let reopened = ReviewResumeStore(defaults: defaults)
        #expect(reopened.lastScope == .category(.screenshot))
        #expect(Calendar.current.isDate(try #require(reopened.lastMonth), equalTo: date, toGranularity: .month))

        reopened.remember(scope: .album("album-123"), containing: nil)
        reopened.remember(scope: .later, containing: nil)
        #expect(ReviewResumeStore(defaults: defaults).lastScope == .album("album-123"))
    }
}

extension ReviewResumeStoreTests {
    @Test("月份跨越越南和洛杉矶时区后仍为原月份")
    func monthScopeSurvivesTimeZoneChange() throws {
        let suite = "ZeyingTests.Resume.MonthZone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vietnam = try Self.testCalendar("Asia/Ho_Chi_Minh")
        let losAngeles = try Self.testCalendar("America/Los_Angeles")
        let april = try #require(vietnam.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        ReviewResumeStore(defaults: defaults, calendar: vietnam).remember(scope: .month(april), containing: april)
        let reopened = ReviewResumeStore(defaults: defaults, calendar: losAngeles)
        guard case .month(let scopeDate) = try #require(reopened.lastScope) else {
            Issue.record("Expected month scope")
            return
        }
        #expect(losAngeles.component(.year, from: scopeDate) == 2026)
        #expect(losAngeles.component(.month, from: scopeDate) == 4)
        let lastMonth = try #require(reopened.lastMonth)
        #expect(losAngeles.component(.month, from: lastMonth) == 4)
        #expect(losAngeles.component(.day, from: lastMonth) == 1)
    }

    @Test("年份跨越越南和洛杉矶时区后仍为原年份")
    func yearScopeSurvivesTimeZoneChange() throws {
        let suite = "ZeyingTests.Resume.YearZone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vietnam = try Self.testCalendar("Asia/Ho_Chi_Minh")
        let losAngeles = try Self.testCalendar("America/Los_Angeles")
        let january = try #require(vietnam.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        ReviewResumeStore(defaults: defaults, calendar: vietnam).remember(scope: .year(january), containing: january)
        guard case .year(let date) = try #require(ReviewResumeStore(defaults: defaults, calendar: losAngeles).lastScope) else {
            Issue.record("Expected year scope")
            return
        }
        #expect(losAngeles.component(.year, from: date) == 2026)
        #expect(losAngeles.component(.month, from: date) == 1)
        #expect(losAngeles.component(.day, from: date) == 1)
    }

    @Test("旧日期不会猜测旧时区，重新选择后写入稳定组件")
    func legacyDateIsRetainedUntilNewChoice() throws {
        let suite = "ZeyingTests.Resume.LegacyZone.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vietnam = try Self.testCalendar("Asia/Ho_Chi_Minh")
        let losAngeles = try Self.testCalendar("America/Los_Angeles")
        let oldDate = try #require(vietnam.date(from: DateComponents(year: 2026, month: 4, day: 1)))
        defaults.set(oldDate.timeIntervalSince1970, forKey: "com.mars.zeying.lastReviewMonth.v1")
        defaults.set(try JSONEncoder().encode(LibraryScope.month(oldDate)), forKey: "com.mars.zeying.lastReviewScope.v1")
        let store = ReviewResumeStore(defaults: defaults, calendar: losAngeles)
        #expect(store.lastMonth == oldDate)
        #expect(store.lastScope == .month(oldDate))
        #expect(defaults.object(forKey: "com.mars.zeying.lastReviewScope.v2") == nil)
        let chosenApril = try #require(losAngeles.date(from: DateComponents(year: 2026, month: 4, day: 2)))
        store.remember(scope: .month(chosenApril), containing: chosenApril)
        #expect(defaults.object(forKey: "com.mars.zeying.lastReviewScope.v1") == nil)
        #expect(defaults.object(forKey: "com.mars.zeying.lastReviewMonth.v1") == nil)
        let restored = ReviewResumeStore(defaults: defaults, calendar: vietnam)
        #expect(vietnam.component(.month, from: try #require(restored.lastMonth)) == 4)
    }

    @Test("续接保留洗牌顺序并过滤处理或不可访问项、追加新照片")
    func savedQueueReconcilesLibraryChanges() throws {
        let suite = "ZeyingTests.Resume.Queue.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ReviewResumeStore(defaults: defaults)
        first.rememberQueue(scope: .random, assetIDs: ["C", "A", "B", "missing", "D", "B"], position: 2, sortMode: .shuffled)
        first.updateQueuePosition(scope: .random, position: 4, currentAssetID: "D")
        let reopened = ReviewResumeStore(defaults: defaults)
        let result = try #require(reopened.restoredQueue(scope: .random, availableAssetIDs: ["A", "B", "C", "D", "E", "E"], reviewedAssetIDs: ["C", "B"]))
        #expect(result.assetIDs == ["A", "D", "E"])
        #expect(result.position == 0)
        #expect(result.currentAssetID == "A")
        #expect(result.sortMode == .shuffled)
        #expect(reopened.restoredQueue(scope: .all, availableAssetIDs: ["A"], reviewedAssetIDs: []) == nil)
    }

    @Test("每张更新只改位置，待决定不会覆盖首页续接")
    func cursorUpdateDoesNotRewriteOrderOrHomeScope() throws {
        let suite = "ZeyingTests.Resume.Cursor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ReviewResumeStore(defaults: defaults)
        store.rememberQueue(scope: .album("family"), assetIDs: ["B", "A", "C"], position: 0, sortMode: .random)
        let orderBefore = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueue.v1"))
        let cursorBefore = defaults.data(forKey: "com.mars.zeying.reviewQueueCursor.v1")
        store.updateQueuePosition(scope: .album("family"), position: 1, currentAssetID: "A")
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueue.v1") == orderBefore)
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueueCursor.v1") != cursorBefore)
        store.rememberQueue(scope: .later, assetIDs: ["later"], position: 0, sortMode: .chronological)
        store.updateQueuePosition(scope: .later, position: 0, currentAssetID: "later")
        store.remember(scope: .later, containing: Date())
        #expect(store.lastScope == .album("family"))
        let result = try #require(ReviewResumeStore(defaults: defaults).restoredQueue(scope: .album("family"), availableAssetIDs: ["A", "B", "C"], reviewedAssetIDs: []))
        #expect(result.assetIDs == ["B", "A", "C"])
        #expect(result.position == 0)
        #expect(result.sortMode == .random)
    }

    @Test("只持久化有界顺序，恢复仍包含所有未处理照片")
    func persistedOrderIsBoundedWithoutDroppingLiveItems() throws {
        let suite = "ZeyingTests.Resume.Bound.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let identifiers = (0..<(ReviewResumeStore.maximumSavedQueueCount + 3)).map { "asset-\($0)" }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        store.rememberQueue(scope: .all, assetIDs: identifiers, position: 0, sortMode: .chronological)
        let data = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueue.v1"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let savedIDs = try #require(json["assetIDs"] as? [String])
        #expect(savedIDs.count == ReviewResumeStore.maximumSavedQueueCount)
        let reopened = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        let result = try #require(reopened.restoredQueue(scope: .all, availableAssetIDs: Array(identifiers.reversed()), reviewedAssetIDs: []))
        #expect(result.assetIDs == identifiers)
    }

    private static func testCalendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }
}
