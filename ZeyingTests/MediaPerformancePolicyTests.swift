import Foundation
import Testing
@testable import Zeying

struct MediaPerformancePolicyTests {
    @Test("正常状态保留两张高清、三张快速预览和一个本地视频")
    func normalPrefetchWindow() {
        #expect(ReviewPrefetchBudget.current(thermalState: .nominal, lowPowerMode: false,
            memoryPressure: false) == ReviewPrefetchBudget(highQualityCount: 2, quickCount: 3, videoCount: 1))
    }

    @Test("发热或低电量保住下一张高清，停止提前准备视频")
    func reducedWindowKeepsNextPhotoReady() {
        for thermal in [ProcessInfo.ThermalState.fair, .serious] {
            #expect(ReviewPrefetchBudget.current(thermalState: thermal, lowPowerMode: false,
                memoryPressure: false) == ReviewPrefetchBudget(highQualityCount: 1, quickCount: 2, videoCount: 0))
        }
        #expect(ReviewPrefetchBudget.current(thermalState: .nominal, lowPowerMode: true,
            memoryPressure: false).highQualityCount == 1)
    }

    @Test("严重过热和内存压力仍保留下一张快速预览")
    func minimumWindowHasVisibleFallback() {
        let minimal = ReviewPrefetchBudget(highQualityCount: 0, quickCount: 1, videoCount: 0)
        #expect(ReviewPrefetchBudget.current(thermalState: .critical, lowPowerMode: false, memoryPressure: false) == minimal)
        #expect(ReviewPrefetchBudget.current(thermalState: .nominal, lowPowerMode: false, memoryPressure: true) == minimal)
    }

    @Test("充电时仍遵守热限制和降速")
    func chargingDoesNotOverrideThermalBudget() {
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .serious,
            background: false, isCharging: true))
        #expect(SuggestionScanPace.foregroundItemDelay(isCharging: true, thermalState: .fair) == .milliseconds(600))
        #expect(SuggestionScanPace.foregroundItemDelay(isCharging: true, lowPowerMode: true) == .milliseconds(600))
    }

    @Test("月份年份分类索引保留日期顺序，无日期照片仍进入媒体分类")
    func indexPreservesOrderAndMissingDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let december = calendar.date(from: DateComponents(year: 2025, month: 12, day: 1))!
        let index = LibraryScopeIndex(entries: [
            LibraryIndexEntry(identifier: "new", creationDate: january.addingTimeInterval(3600), categories: [.photo, .livePhoto]),
            LibraryIndexEntry(identifier: "same-month", creationDate: january, categories: [.photo]),
            LibraryIndexEntry(identifier: "old", creationDate: december, categories: [.video]),
            LibraryIndexEntry(identifier: "undated", creationDate: nil, categories: [.photo, .screenshot])
        ], calendar: calendar)
        #expect(index.months == [january, december])
        #expect(index.identifiersByScope[.month(january)] == ["new", "same-month"])
        #expect(index.identifiersByScope[.category(.photo)] == ["new", "same-month", "undated"])
        #expect(index.identifiersByScope[.category(.screenshot)] == ["undated"])
        #expect(index.years.count == 2)
    }

    @Test("跨轮缓存优先保留最近用过的结果，替换不突破容量")
    func reuseCacheEvictsLeastRecentlyUsed() {
        var cache = BoundedCache<String, Int>(capacity: 2)
        cache.insert(1, for: "first")
        cache.insert(2, for: "second")
        #expect(cache.value(for: "first") == 1)
        cache.insert(3, for: "third")
        #expect(cache.value(for: "second") == nil)
        cache.insert(4, for: "first")
        #expect(cache.count == 2)
        #expect(cache.value(for: "first") == 4)
        var disabled = BoundedCache<String, Int>(capacity: 0)
        disabled.insert(1, for: "value")
        #expect(disabled.count == 0)
        // Repeated eviction/replacement must keep the linked order coherent.
        for index in 0..<10_000 { cache.insert(index, for: "key-\(index)") }
        #expect(cache.count == 2)
        #expect(cache.value(for: "key-9999") == 9999)
        #expect(cache.value(for: "key-9998") == 9998)
    }

    @Test("取消分组时不继续执行昂贵的距离比较")
    func cancelledGroupingStopsBeforeComparison() {
        let assets = (0..<500).map {
            SuggestionAsset(id: "photo-\($0)", modifiedAt: nil, createdAt: nil,
                width: 1500, height: 1500, isScreenshot: false, isLivePhoto: false,
                burstID: nil, isProtected: false, isEligible: true)
        }
        let result = SuggestionGrouping.build(assets: assets, analyses: [:], isCancelled: { true }) { _, _ in
            Issue.record("取消后的分组仍调用了距离比较")
            return 0
        }
        #expect(result.isEmpty)
    }
}
