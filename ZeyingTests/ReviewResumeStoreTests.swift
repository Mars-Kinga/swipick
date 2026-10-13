import Foundation
import Testing
@testable import Zeying

@MainActor
struct ReviewResumeStoreTests {
    @Test("随机会切换当前照片，切回顺序不丢失剩余照片")
    func shuffleAndRestoreCurrentPhoto() {
        let original = ["reviewed", "a", "b", "c", "d"]
        for _ in 0..<20 {
            let shuffled = ReviewQueueOrdering.shuffled(Array(original.dropFirst()))
            #expect(shuffled.first != "a")
            #expect(Set(shuffled) == Set(original.dropFirst()))
            let restored = ReviewQueueOrdering.restored(shuffled, originalOrder: original)
            #expect(restored == Array(original.dropFirst()))
        }
    }

    @Test("恢复顺序会保留原快照之后新增的照片")
    func restoreKeepsNewerItems() {
        #expect(ReviewQueueOrdering.restored(["new", "b", "a"], originalOrder: ["a", "b"]) == ["a", "b", "new"])
    }

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
        first.rememberQueue(scope: .random, assetIDs: ["C", "A", "B", "missing", "D", "B"], sortMode: .shuffled)
        let reopened = ReviewResumeStore(defaults: defaults)
        let result = try #require(reopened.restoredQueue(scope: .random, availableAssetIDs: ["A", "B", "C", "D", "E", "E"], reviewedAssetIDs: ["C", "B"]))
        #expect(result.assetIDs == ["A", "D", "E"])
        #expect(result.position == 0)
        #expect(result.currentAssetID == "A")
        #expect(result.sortMode == .shuffled)
        #expect(reopened.restoredQueue(scope: .all, availableAssetIDs: ["A"], reviewedAssetIDs: []) == nil)
    }

    @Test("旧逐张游标清理后仍可续接队列")
    func obsoleteCursorRemovalKeepsQueueAndHomeScope() throws {
        let suite = "ZeyingTests.Resume.Cursor.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: "com.mars.zeying.reviewQueueCursor.v1")
        let store = ReviewResumeStore(defaults: defaults)
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueueCursor.v1") == nil)
        store.rememberQueue(scope: .album("family"), assetIDs: ["B", "A", "C"], sortMode: .random)
        let orderBefore = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
        store.rememberQueue(scope: .later, assetIDs: ["later"], sortMode: .chronological)
        store.remember(scope: .later, containing: Date())
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2") == orderBefore)
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
        store.rememberQueue(scope: .all, assetIDs: identifiers, sortMode: .chronological)
        let data = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let savedIDs = try #require(json.first?["assetIDs"] as? [String])
        #expect(savedIDs.count == ReviewResumeStore.maximumSavedQueueCount)
        let reopened = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        let result = try #require(reopened.restoredQueue(scope: .all, availableAssetIDs: Array(identifiers.reversed()), reviewedAssetIDs: []))
        #expect(result.assetIDs == identifiers)
    }

    @Test("最近两组可交替恢复各自的顺序")
    func alternatingRecentQueuesRestore() throws {
        let suite = "ZeyingTests.Resume.Alternating.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReviewResumeAlternating.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        first.rememberQueue(
            scope: .album("A"), assetIDs: ["A-3", "A-1", "A-2"],
            sortMode: .shuffled
        )
        first.rememberQueue(
            scope: .album("B"), assetIDs: ["B-2", "B-1"],
            sortMode: .chronological
        )

        let reopened = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        let a = try #require(reopened.restoredQueue(
            scope: .album("A"), availableAssetIDs: ["A-1", "A-2", "A-3", "A-new"],
            reviewedAssetIDs: []
        ))
        #expect(a.assetIDs == ["A-3", "A-1", "A-2", "A-new"])
        #expect(a.position == 0)
        #expect(a.sortMode == .shuffled)

        let b = try #require(reopened.restoredQueue(
            scope: .album("B"), availableAssetIDs: ["B-1", "B-2", "B-new"],
            reviewedAssetIDs: []
        ))
        #expect(b.assetIDs == ["B-2", "B-1", "B-new"])
        #expect(b.position == 0)
        #expect(b.sortMode == .chronological)
    }

    @Test("第三组淘汰最旧组，再次打开旧组淘汰另一组")
    func recentQueueEvictionAndReopen() throws {
        let suite = "ZeyingTests.Resume.Eviction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReviewResumeEviction.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        store.rememberQueue(scope: .album("A"), assetIDs: ["A"], sortMode: .random)
        store.rememberQueue(scope: .album("B"), assetIDs: ["B"], sortMode: .random)
        store.rememberQueue(scope: .album("C"), assetIDs: ["C"], sortMode: .random)
        let afterCData = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
        let afterCQueues = try #require(JSONSerialization.jsonObject(with: afterCData) as? [[String: Any]])
        #expect(afterCQueues.count == 2)

        let afterC = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        #expect(afterC.restoredQueue(scope: .album("A"), availableAssetIDs: ["A"], reviewedAssetIDs: []) == nil)
        #expect(afterC.restoredQueue(scope: .album("B"), availableAssetIDs: ["B"], reviewedAssetIDs: []) != nil)
        #expect(afterC.restoredQueue(scope: .album("C"), availableAssetIDs: ["C"], reviewedAssetIDs: []) != nil)

        afterC.rememberQueue(scope: .album("A"), assetIDs: ["A-again"], sortMode: .shuffled)
        let afterAData = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
        let afterAQueues = try #require(JSONSerialization.jsonObject(with: afterAData) as? [[String: Any]])
        #expect(afterAQueues.count == 2)
        let afterA = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        #expect(afterA.restoredQueue(scope: .album("B"), availableAssetIDs: ["B"], reviewedAssetIDs: []) == nil)
        #expect(afterA.restoredQueue(scope: .album("C"), availableAssetIDs: ["C"], reviewedAssetIDs: []) != nil)
        #expect(afterA.restoredQueue(scope: .album("A"), availableAssetIDs: ["A-again"], reviewedAssetIDs: [])?.assetIDs == ["A-again"])
    }

    @Test("旧 v1 单组记录可恢复并在下一次保存迁移到 v2")
    func legacyQueueMigratesOnNextSave() throws {
        let suite = "ZeyingTests.Resume.LegacyQueue.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReviewResumeLegacy.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        writer.rememberQueue(scope: .album("A"), assetIDs: ["A-1", "A-2"], sortMode: .shuffled)
        let v2Data = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
        let v2Objects = try #require(JSONSerialization.jsonObject(with: v2Data) as? [[String: Any]])
        let legacyData = try JSONSerialization.data(withJSONObject: try #require(v2Objects.first))
        defaults.set(legacyData, forKey: "com.mars.zeying.reviewQueue.v1")
        defaults.removeObject(forKey: "com.mars.zeying.reviewQueues.v2")

        let migrated = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        let restored = try #require(migrated.restoredQueue(
            scope: .album("A"), availableAssetIDs: ["A-1", "A-2"], reviewedAssetIDs: []
        ))
        #expect(restored.assetIDs == ["A-1", "A-2"])

        migrated.rememberQueue(scope: .album("B"), assetIDs: ["B"], sortMode: .chronological)
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2") != nil)
        #expect(defaults.data(forKey: "com.mars.zeying.reviewQueue.v1") == nil)
        #expect(ReviewResumeStore(defaults: defaults, storageDirectory: directory)
            .restoredQueue(scope: .album("A"), availableAssetIDs: ["A-1", "A-2"], reviewedAssetIDs: []) != nil)
    }

    @Test("两组 overflow 文件保留，第三组淘汰时只清理被淘汰组")
    func overflowFilesFollowRecentQueueEviction() throws {
        let suite = "ZeyingTests.Resume.OverflowEviction.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "ReviewResumeOverflow.\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ReviewResumeStore(defaults: defaults, storageDirectory: directory)
        func assets(_ prefix: String) -> [String] {
            (0..<(ReviewResumeStore.maximumSavedQueueCount + 1)).map { "\(prefix)-\($0)" }
        }
        func queueID(at index: Int) throws -> UUID {
            let data = try #require(defaults.data(forKey: "com.mars.zeying.reviewQueues.v2"))
            let queues = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
            let rawID = try #require(queues[index]["id"] as? String)
            return try #require(UUID(uuidString: rawID))
        }
        func overflowURL(for id: UUID) -> URL {
            directory.appending(path: "\(id.uuidString).json")
        }

        store.rememberQueue(scope: .album("A"), assetIDs: assets("A"), sortMode: .random)
        let aID = try queueID(at: 0)
        #expect(FileManager.default.fileExists(atPath: overflowURL(for: aID).path))

        store.rememberQueue(scope: .album("B"), assetIDs: assets("B"), sortMode: .random)
        let bID = try queueID(at: 0)
        #expect(FileManager.default.fileExists(atPath: overflowURL(for: aID).path))
        #expect(FileManager.default.fileExists(atPath: overflowURL(for: bID).path))

        store.rememberQueue(scope: .album("C"), assetIDs: assets("C"), sortMode: .random)
        let cID = try queueID(at: 0)
        #expect(!FileManager.default.fileExists(atPath: overflowURL(for: aID).path))
        #expect(FileManager.default.fileExists(atPath: overflowURL(for: bID).path))
        #expect(FileManager.default.fileExists(atPath: overflowURL(for: cID).path))
    }

    private static func testCalendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        return calendar
    }
}
