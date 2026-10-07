import Foundation
import Testing
@testable import Zeying

struct SuggestionScreenshotAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func screenshot(_ id: String, age: TimeInterval, protected: Bool = false) -> SuggestionAsset {
        SuggestionAsset(id: id, modifiedAt: now, createdAt: now.addingTimeInterval(-age),
                        width: 1200, height: 1600, isScreenshot: true, isLivePhoto: false,
                        burstID: nil, isProtected: protected, isEligible: !protected)
    }

    private func analysis(_ asset: SuggestionAsset, kind: TemporaryScreenshotKind,
                          checked: Bool? = true, hasPastEvent: Bool = false,
                          eventDates: [Date]? = nil) -> SuggestionAnalysis {
        SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(), hasPastEvent: hasPastEvent,
                           eventDates: eventDates, temporaryScreenshotKind: kind,
                           screenshotContentChecked: checked)
    }

    @Test("近期截图不进入时间建议，收藏旧截图仍受保护")
    func recentAndProtectedScreenshotsStayOut() {
        let recent = screenshot("ticket", age: 86_400)
        let favorite = screenshot("favorite", age: 120 * 86_400, protected: true)
        let analyses = [
            recent.id: analysis(recent, kind: .completedOrders),
            favorite.id: analysis(favorite, kind: .completedOrders)
        ]
        let groups = SuggestionGrouping.build(assets: [recent, favorite], analyses: analyses, now: now) { _, _ in nil }
        #expect(groups.isEmpty)
    }

    @Test("旧截图建议严格超过 90 天，时间跨过边界后重建可加入")
    func oldScreenshotBoundaryMovesWithTime() {
        let item = screenshot("boundary", age: 90 * 86_400)
        let analyses = [item.id: analysis(item, kind: .completedOrders)]
        #expect(SuggestionGrouping.build(assets: [item], analyses: analyses, now: now) { _, _ in nil }.isEmpty)
        let later = SuggestionGrouping.build(assets: [item], analyses: [:], now: now.addingTimeInterval(1)) { _, _ in nil }
        #expect(later.isEmpty)

        let afterBoundary = SuggestionGrouping.build(assets: [item], analyses: analyses, now: now.addingTimeInterval(1)) { _, _ in nil }
        #expect(afterBoundary.first?.kind == .screenshots)
        #expect(afterBoundary.first?.reason == .olderOrders)
        #expect(afterBoundary.first?.recommendedKeepID == nil)
    }

    @Test("同一内容类别的 25 张以上旧截图组成一个完整队列，不按月份拆分")
    func sameCategoryStaysInOneQueueAcrossMonths() {
        let calendar = Calendar.current
        let firstDate = calendar.date(from: DateComponents(year: 2024, month: 12, day: 15))!
        let secondDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15))!
        let assets = (0..<25).map { screenshot("dec-\($0)", age: now.timeIntervalSince(firstDate)) }
            + [screenshot("jan", age: now.timeIntervalSince(secondDate))]
        let analyses = Dictionary(uniqueKeysWithValues: assets.map {
            ($0.id, analysis($0, kind: .pickupCodes))
        })
        let groups = SuggestionGrouping.build(assets: assets, analyses: analyses, now: now) { _, _ in nil }
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .screenshots)
        #expect(groups.first?.reason == .olderPickupCodes)
        #expect(groups.first?.assetIDs.count == 26)
        #expect(Set(groups.flatMap(\.assetIDs)).count == 26)
        #expect(groups.first?.assetIDs.contains("jan") == true)
    }

    @Test("已送达物流和过期优惠券各自成组，普通旧截图不混入")
    func additionalTemporaryKindsStaySelective() {
        let delivery = screenshot("delivery", age: 120 * 86_400)
        let coupon = screenshot("coupon", age: 150 * 86_400)
        let ordinary = screenshot("ordinary", age: 180 * 86_400)
        let groups = SuggestionGrouping.build(
            assets: [delivery, coupon, ordinary],
            analyses: [delivery.id: analysis(delivery, kind: .completedDeliveries),
                       coupon.id: analysis(coupon, kind: .expiredOffers)],
            now: now
        ) { _, _ in nil }
        #expect(groups.count == 2)
        #expect(groups.contains { $0.reason == .olderDeliveries && $0.assetIDs == [delivery.id] })
        #expect(groups.contains { $0.reason == .expiredOffers && $0.assetIDs == [coupon.id] })
        #expect(groups.allSatisfy { !$0.assetIDs.contains(ordinary.id) })
    }

    @Test("活动当天仍可用，下一天之后才建议；跨年与闰年日期可识别")
    func eventDayAndYearBoundaries() {
        let calendar = Calendar.current
        let during = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 23))!
        let after = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 1))!
        #expect(!ScreenshotEventDate.hasPastEvent(in: "concert 2025-12-31", now: during))
        #expect(ScreenshotEventDate.hasPastEvent(in: "concert 2025-12-31", now: after))
        #expect(ScreenshotEventDate.hasPastEvent(in: "活动 2024-02-29", now: after))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "活动 2025-02-29", now: after))
    }

    @Test("无本地预览且没有缓存内容证据的旧截图不推断为临时内容")
    func unavailablePreviewDoesNotInventAnEvent() {
        #expect(!ScreenshotEventDate.hasPastEvent(in: "报名 2099年1月1日", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "入场 1月1日", now: now))
        let old = screenshot("cloud-only", age: 100 * 86_400)
        let groups = SuggestionGrouping.build(assets: [old], analyses: [:], now: now) { _, _ in nil }
        #expect(groups.isEmpty)
    }

    @Test("缓存合法日期后，活动可随时间到期，不需要重新识别截图")
    func cachedEventDatesAreReevaluated() {
        let event = Calendar.current.date(from: DateComponents(year: 2025, month: 12, day: 31))!
        let during = event.addingTimeInterval(12 * 3600)
        let after = Calendar.current.date(byAdding: .day, value: 2, to: event)!
        let item = screenshot("ticket", age: 86_400)
        let analysis = SuggestionAnalysis(asset: item, differenceHash: 0, featurePrint: Data(), hasPastEvent: false,
                                          eventDates: ScreenshotEventDate.eventDates(in: "concert 2025-12-31"),
                                          temporaryScreenshotKind: .pastEvents, screenshotContentChecked: true)
        #expect(!analysis.hasPastEvent(at: during))
        #expect(analysis.hasPastEvent(at: after))
    }

    @Test("日期不能截取更长年份或日数字中的合法前缀")
    func malformedDatePrefixesStayOut() {
        #expect(!ScreenshotEventDate.hasPastEvent(in: "活动 2025-01-011", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "活动 12025-01-01", now: now))
    }
}
