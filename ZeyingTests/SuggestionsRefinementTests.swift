import Foundation
import Testing
import UIKit
@testable import Zeying

struct SuggestionsRefinementTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func screenshot(_ id: String, age: TimeInterval) -> SuggestionAsset {
        SuggestionAsset(id: id, modifiedAt: now, createdAt: now.addingTimeInterval(-age),
                        width: 1200, height: 1600, isScreenshot: true, isLivePhoto: false,
                        burstID: nil, isProtected: false, isEligible: true)
    }

    private func analysis(_ asset: SuggestionAsset, kind: TemporaryScreenshotKind? = nil,
                          checked: Bool? = nil, hasPastEvent: Bool = false) -> SuggestionAnalysis {
        SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(), hasPastEvent: hasPastEvent,
                           temporaryScreenshotKind: kind, screenshotContentChecked: checked)
    }

    private func group(_ id: String) -> CleanupSuggestion {
        CleanupSuggestion(id: id, kind: .screenshots, reason: .olderOrders, assetIDs: ["\(id)-asset"],
                          recommendedKeepID: nil, protectedIDs: [], knownBytes: nil, newestDate: nil)
    }

    @Test("重新打开时恢复上次发现的建议与完成时间")
    @MainActor
    func suggestionGroupsSurviveRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "suggestions-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "groups-v1.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let original = [group("one"), group("two")]
        try SuggestionGroupSnapshot(groups: original, hasScanned: true, lastScanDate: date).save(to: url)

        let suiteName = "ZeyingTests.Suggestions.Restore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reopened = PhotoSuggestionService(defaults: defaults, snapshotURL: url)
        #expect(reopened.groups == original)
        #expect(reopened.hasScanned)
        #expect(reopened.lastScanDate == date)
    }

    @Test("检查进度写入本地快照并在重开后恢复百分比")
    @MainActor
    func suggestionProgressSurvivesRelaunch() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "suggestions-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "groups-v1.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let progress = SuggestionScanProgress(checked: 50, total: 100, unavailable: 2)
        try SuggestionGroupSnapshot(groups: [group("saved")], hasScanned: false,
                                    lastScanDate: nil, progress: progress).save(to: url)
        let reopened = PhotoSuggestionService(snapshotURL: url)
        #expect(reopened.checkedCount == 50)
        #expect(reopened.totalCount == 100)
        #expect(reopened.unavailableCount == 2)
        #expect(reopened.scanProgressPercent == 50)
        #expect(reopened.groups.count == 1)
    }

    @Test("重新扫描从有效分析缓存计算已检查数量，未完成截图不计入")
    func cachedAnalysisRestoresCheckedCount() {
        let normal = SuggestionAsset(id: "photo", modifiedAt: now, createdAt: now, width: 1200,
                                     height: 1600, isScreenshot: false, isLivePhoto: false,
                                     burstID: nil, isProtected: false, isEligible: true)
        let finished = screenshot("finished", age: 120 * 86_400)
        let stale = screenshot("stale", age: 120 * 86_400)
        var classified = analysis(finished, kind: .completedOrders, checked: true)
        classified.eventDates = []
        classified.screenshotClassifierVersion = TemporaryScreenshotClassifier.version
        let progress = SuggestionScanProgress.fromCache(
            assets: [normal, finished, stale],
            analyses: [normal.id: analysis(normal), finished.id: classified, stale.id: analysis(stale)]
        )
        #expect(progress.checked == 2)
        #expect(progress.total == 3)
        #expect(progress.percentage(complete: false) == 66)
        #expect(progress.percentage(complete: true) == 100)
    }

    @Test("旧分组保留可见并重新检查，以应用新的相似照片分组规则")
    @MainActor
    func olderGroupingSnapshotSchedulesRefresh() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "suggestions-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "groups-v1.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let original = [group("old")]
        try SuggestionGroupSnapshot(groups: original, hasScanned: true, lastScanDate: .now,
                                    groupingVersion: nil).save(to: url)
        let reopened = PhotoSuggestionService(snapshotURL: url)
        #expect(reopened.groups == original)
        #expect(!reopened.hasScanned)
        #expect(reopened.lastScanDate == nil)
    }

    @Test("扫描的初始空结果不会清掉旧建议，完整结果才替换")
    func partialScanKeepsPreviousSuggestions() {
        let old = group("old")
        let added = group("added")
        #expect(SuggestionGroupProgress.merge(previous: [old], incoming: [], complete: false) == [old])
        #expect(SuggestionGroupProgress.merge(previous: [old], incoming: [added], complete: false) == [added, old])
        #expect(SuggestionGroupProgress.merge(previous: [old], incoming: [], complete: true).isEmpty)

        let overlapping = CleanupSuggestion(id: "new", kind: .similar, reason: .nearbyShots,
                                             assetIDs: old.assetIDs, recommendedKeepID: nil,
                                             protectedIDs: [], knownBytes: nil, newestDate: nil)
        #expect(SuggestionGroupProgress.merge(previous: [old], incoming: [overlapping], complete: false) == [overlapping])
    }

    @Test("图库刷新不会中断正在进行的建议检查")
    func scanRevisionChangeWaitsForCurrentPass() {
        #expect(!SuggestionScanStartPolicy.shouldStart(
            manuallyPaused: false, isScanning: true, scannedRevision: 1, currentRevision: 2,
            hasScanned: false, needsDailyRefresh: true
        ))
        #expect(SuggestionScanStartPolicy.shouldStart(
            manuallyPaused: false, isScanning: false, scannedRevision: 1, currentRevision: 2,
            hasScanned: true, needsDailyRefresh: false
        ))
        #expect(!SuggestionScanStartPolicy.shouldStart(
            manuallyPaused: false, isScanning: false, scannedRevision: 2, currentRevision: 2,
            hasScanned: true, needsDailyRefresh: false
        ))
    }

    @Test("旧分析缓存缺字段或含坏记录时仍恢复其余结果")
    func legacyAnalysisCacheSalvagesValidRows() throws {
        let asset = screenshot("good", age: 120 * 86_400)
        let good = analysis(asset, kind: .completedOrders, checked: true)
        let encoded = try JSONEncoder().encode(["good": good])
        var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: [String: Any]])
        root["good"]?["checkedResources"] = nil
        root["bad"] = ["unrelated": "broken"]
        let legacyData = try JSONSerialization.data(withJSONObject: root)

        let recovered = try #require(SuggestionAnalysisCache.decode(legacyData))
        #expect(recovered.count == 1)
        #expect(recovered["good"]?.matches(asset) == true)
        #expect(recovered["good"]?.checkedResources == false)
    }

    @Test("仅有本地缩略图时仍可用于建议分析")
    @MainActor
    func localThumbnailSurvivesMissingCloudOriginal() async {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let request = SuggestionPreviewRequest()
        let returned = await withCheckedContinuation { continuation in
            #expect(request.install(continuation))
            request.offerLocalThumbnail(image)
            request.finish(nil)
        }
        #expect(returned?.cgImage?.width == image.cgImage?.width)
        #expect(returned?.cgImage?.height == image.cgImage?.height)
    }

    @Test("旧截图优先检查，近期截图不进入临时截图扫描")
    func scanStartsWithOldScreenshots() {
        let recent = screenshot("recent", age: 3 * 86_400)
        let old = screenshot("old", age: 120 * 86_400)
        let photo = SuggestionAsset(id: "ordinary", modifiedAt: now, createdAt: now,
                                    width: 1200, height: 1600, isScreenshot: false, isLivePhoto: false,
                                    burstID: nil, isProtected: false, isEligible: true)
        #expect(SuggestionScanOrder.ordered([photo, recent, old], now: now).map(\.id) == ["old", "ordinary"])
    }

    @Test("旧截图多时也会穿插检查普通照片")
    func manyScreenshotsDoNotStarveSimilarPhotos() {
        let screenshots = (0..<3).map { screenshot("screen-\($0)", age: TimeInterval(120 + $0) * 86_400) }
        let photos = (0..<5).map { index in
            SuggestionAsset(id: "photo-\(index)", modifiedAt: now,
                            createdAt: now.addingTimeInterval(-TimeInterval(index) * 86_400),
                            width: 1200, height: 1600, isScreenshot: false, isLivePhoto: false,
                            burstID: nil, isProtected: false, isEligible: true)
        }
        #expect(SuggestionScanOrder.ordered(screenshots + photos, now: now).map(\.id) == [
            "screen-0", "photo-0", "photo-1", "photo-2", "photo-3",
            "screen-1", "photo-4", "screen-2"
        ])
    }

    @Test("临时截图分类需要明确的完成状态或一次性内容证据")
    func classifierRequiresConcreteTemporaryContent() {
        #expect(TemporaryScreenshotClassifier.classify("订单 12345，支付成功") == .completedOrders)
        #expect(TemporaryScreenshotClassifier.classify("订单 12345，交易完成") == .completedOrders)
        #expect(TemporaryScreenshotClassifier.classify("取件码：AB12CD") == .pickupCodes)
        #expect(TemporaryScreenshotClassifier.classify("验证码 493021") == .verificationCodes)
        #expect(TemporaryScreenshotClassifier.classify("音乐会 2025-12-31") == .pastEvents)
        #expect(TemporaryScreenshotClassifier.classify("快递包裹 已签收") == .completedDeliveries)
        #expect(TemporaryScreenshotClassifier.classify("优惠券 已过期") == .expiredOffers)

        #expect(TemporaryScreenshotClassifier.classify("这是一篇关于旅行的文章") == nil)
        #expect(TemporaryScreenshotClassifier.classify("你吃饭了吗？明天见") == nil)
        #expect(TemporaryScreenshotClassifier.classify("订单已创建，等待付款") == nil)
        #expect(TemporaryScreenshotClassifier.classify("快递正在派送") == nil)
        #expect(TemporaryScreenshotClassifier.classify("优惠券还可以使用") == nil)
    }

    @Test("分类规则更新后旧截图缓存必须重新识别，普通照片缓存可保留")
    func screenshotClassifierVersionInvalidatesOldCache() {
        let old = screenshot("old-cache", age: 120 * 86_400)
        let legacy = SuggestionAnalysis(asset: old, differenceHash: 0, featurePrint: Data(), hasPastEvent: false,
                                        eventDates: [], screenshotContentChecked: true)
        #expect(!legacy.hasCurrentScreenshotClassification)
        var current = legacy
        current.screenshotClassifierVersion = TemporaryScreenshotClassifier.version
        #expect(current.hasCurrentScreenshotClassification)

        let photo = SuggestionAsset(id: "photo", modifiedAt: now, createdAt: now, width: 1200, height: 1600,
                                    isScreenshot: false, isLivePhoto: false, burstID: nil,
                                    isProtected: false, isEligible: true)
        let photoCache = SuggestionAnalysis(asset: photo, differenceHash: 1, featurePrint: Data(), hasPastEvent: false)
        #expect(photoCache.hasCurrentScreenshotClassification)
    }

    @Test("只有严格超过 90 天且完成内容检查的旧截图才能进入分类建议")
    func screenshotSuggestionsRequireAgeAndCheckedEvidence() {
        let old = screenshot("old", age: 90 * 86_400 + 1)
        let exactBoundary = screenshot("boundary", age: 90 * 86_400)
        let recent = screenshot("recent", age: 2 * 86_400)
        let unchecked = screenshot("unchecked", age: 365 * 86_400)
        let unclassified = screenshot("unclassified", age: 365 * 86_400)
        let noEvidence = screenshot("no-evidence", age: 365 * 86_400)
        let analyses = [
            old.id: analysis(old, kind: .completedOrders, checked: true),
            exactBoundary.id: analysis(exactBoundary, kind: .completedOrders, checked: true),
            recent.id: analysis(recent, kind: .completedOrders, checked: true),
            unchecked.id: analysis(unchecked, kind: .completedOrders, checked: false),
            unclassified.id: analysis(unclassified, kind: nil, checked: true)
        ]

        let groups = SuggestionGrouping.build(
            assets: [old, exactBoundary, recent, unchecked, unclassified, noEvidence],
            analyses: analyses,
            now: now
        ) { _, _ in nil }

        #expect(groups.count == 1)
        #expect(groups.first?.reason == .olderOrders)
        #expect(groups.first?.assetIDs == [old.id])
    }

    @Test("过去活动类别只有活动已经过去时才进入建议")
    func pastEventCategoryRequiresExpiredEvent() {
        let past = screenshot("past", age: 120 * 86_400)
        let upcoming = screenshot("upcoming", age: 120 * 86_400)
        let analyses = [
            past.id: analysis(past, kind: .pastEvents, checked: true, hasPastEvent: true),
            upcoming.id: analysis(upcoming, kind: .pastEvents, checked: true, hasPastEvent: false)
        ]

        let groups = SuggestionGrouping.build(assets: [past, upcoming], analyses: analyses, now: now) { _, _ in nil }
        #expect(groups.count == 1)
        #expect(groups.first?.reason == .pastEvent)
        #expect(groups.first?.assetIDs == [past.id])
    }

    @Test("不同临时内容类别分别排队，类别之间不混组")
    func temporaryCategoriesRemainSeparate() {
        let order = screenshot("order", age: 120 * 86_400)
        let pickup = screenshot("pickup", age: 121 * 86_400)
        let analyses = [
            order.id: analysis(order, kind: .completedOrders, checked: true),
            pickup.id: analysis(pickup, kind: .pickupCodes, checked: true)
        ]

        let groups = SuggestionGrouping.build(assets: [order, pickup], analyses: analyses, now: now) { _, _ in nil }
        #expect(groups.count == 2)
        #expect(groups.contains { $0.reason == .olderOrders })
        #expect(groups.contains { $0.reason == .olderPickupCodes })
        #expect(groups.allSatisfy { $0.assetIDs.count == 1 })
    }

    @Test("截图永远不参与视觉相似组")
    func screenshotsStayOutOfVisualSimilarity() {
        let first = screenshot("first", age: 120 * 86_400)
        let second = screenshot("second", age: 121 * 86_400)
        let analyses = [
            first.id: analysis(first, kind: .pickupCodes, checked: true),
            second.id: analysis(second, kind: .pickupCodes, checked: true)
        ]

        let groups = SuggestionGrouping.build(assets: [first, second], analyses: analyses, now: now) { _, _ in 0 }
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .screenshots)
        #expect(groups.first?.reason == .olderPickupCodes)
        #expect(!groups.contains { $0.kind == .similar })
    }

    @Test("点击某个建议组后保留完整队列，既能向前也能向后滑")
    func reviewQueueKeepsPreviousGroupsAvailable() {
        let groups = [group("first"), group("selected"), group("last")]
        #expect(SuggestionReviewQueue.initialIndex(of: groups[1], in: groups) == 1)
        #expect(SuggestionReviewQueue.initialIndex(of: nil, in: groups) == 0)
    }

    @Test("低电量或严重温度状态暂停后台检查")
    func backgroundCheckBudgetPausesForPowerAndThermalState() {
        #expect(!SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .nominal))
        #expect(!SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .fair))
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: true, thermalState: .nominal))
        #expect(!SuggestionCheckBudget.shouldPause(lowPowerMode: true, thermalState: .nominal, isCharging: true))
        #expect(!SuggestionCheckBudget.shouldPause(lowPowerMode: true, thermalState: .nominal, background: false))
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .serious))
        #expect(!SuggestionCheckBudget.shouldPause(lowPowerMode: true, thermalState: .serious, background: false))
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .critical))
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .critical, background: false))
        #expect(SuggestionCheckBudget.shouldPause(lowPowerMode: false, thermalState: .critical, isCharging: true))
        #expect(SuggestionScanPace.analysisLimit(isCharging: true) == .max)
        #expect(SuggestionScanPace.analysisLimit(isCharging: false) == 48)
        #expect(SuggestionScanPace.resourceLimit(isCharging: false) == 4)
        #expect(SuggestionScanPace.itemDelay(isCharging: false) == .milliseconds(300))
    }

    @Test("已有相簿待办的截图不会再次进入建议队列")
    @MainActor
    func pendingAlbumScreenshotIsProtectedAlongsideReviewDecisions() {
        #expect(PhotoSuggestionService.isEligibleScreenshotAsset(
            isFavorite: false, hasDecision: false, isPendingFavorite: false, hasAlbumAssignment: false
        ))
        #expect(!PhotoSuggestionService.isEligibleScreenshotAsset(
            isFavorite: false, hasDecision: false, isPendingFavorite: false, hasAlbumAssignment: true
        ))
        #expect(!PhotoSuggestionService.isEligibleScreenshotAsset(
            isFavorite: false, hasDecision: true, isPendingFavorite: false, hasAlbumAssignment: false
        ))
    }

    @Test("低电量暂停后的后台重试使用长退避，普通失败仍可快速恢复")
    @MainActor
    func backgroundRetryBackoffMatchesPowerState() {
        #expect(PhotoSuggestionBackgroundTask.retryDelay(success: true, energyPaused: false) == 12 * 60 * 60)
        #expect(PhotoSuggestionBackgroundTask.retryDelay(success: false, energyPaused: true) == 6 * 60 * 60)
        #expect(PhotoSuggestionBackgroundTask.retryDelay(success: false, energyPaused: false) == 15 * 60)
        #expect(PhotoSuggestionBackgroundTask.retryDelay(success: false, energyPaused: false, isCharging: true) == 0)
    }

    @Test("后台资源验证跳过冷却中的失败项并继续后续副本")
    func resourceVerificationDoesNotStarveLaterCopies() {
        let assets = (0..<10).map { index in
            SuggestionAsset(
                id: "resource-\(index)", modifiedAt: now, createdAt: now,
                width: 1600, height: 1200, isScreenshot: false, isLivePhoto: false,
                burstID: nil, isProtected: false, isEligible: true
            )
        }
        let analyses = Dictionary(uniqueKeysWithValues: assets.map { asset in
            (asset.id, SuggestionAnalysis(asset: asset, differenceHash: 0, featurePrint: Data(), hasPastEvent: false))
        })
        let nominated = Set(assets.map(\.id))
        let failures = [
            assets[0].id: now.addingTimeInterval(-60 * 60),
            assets[1].id: now.addingTimeInterval(-60 * 60)
        ]

        let candidates = SuggestionResourceVerification.candidates(
            assets: assets, nominated: nominated, analyses: analyses, failures: failures,
            background: true, now: now
        )
        #expect(candidates.map(\.id) == assets.dropFirst(2).map(\.id))

        let afterCooldown = SuggestionResourceVerification.candidates(
            assets: assets, nominated: nominated, analyses: analyses, failures: failures,
            background: true, now: now.addingTimeInterval(SuggestionResourceVerification.failureCooldown + 1)
        )
        #expect(afterCooldown.map(\.id) == assets.map(\.id))
    }

    @Test("手动暂停在隔离的 UserDefaults suite 中持久化，并关闭后台检查")
    @MainActor
    func manualPausePersistsAndDisablesBackgroundChecking() throws {
        let suiteName = "ZeyingTests.Suggestions.ManualPause.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "com.mars.zeying.suggestionBackgroundCheck.v1")
        let service = PhotoSuggestionService(defaults: defaults)
        #expect(service.backgroundCheckingEnabled)

        service.pause(manually: true)
        #expect(service.isManuallyPaused)
        #expect(!service.backgroundCheckingEnabled)

        let reopened = PhotoSuggestionService(defaults: defaults)
        #expect(reopened.isManuallyPaused)
        #expect(!reopened.backgroundCheckingEnabled)
    }

    @Test("首次使用即允许系统调度建议后台检查，手动暂停仍优先")
    @MainActor
    func backgroundCheckingDefaultsOn() throws {
        let suiteName = "ZeyingTests.Suggestions.BackgroundDefault.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = PhotoSuggestionService(defaults: defaults)
        #expect(service.backgroundCheckingEnabled)
        service.pause(manually: true)
        #expect(!PhotoSuggestionService(defaults: defaults).backgroundCheckingEnabled)
    }

    @Test("删除新增字段后的旧截图分析 JSON 仍可解码，并保留非截图 Vision 缓存匹配")
    func legacyAnalysisWithoutRefinementFieldsStillDecodes() throws {
        let asset = SuggestionAsset(id: "legacy-photo", modifiedAt: now, createdAt: now.addingTimeInterval(-86_400),
                                    width: 1600, height: 1200, isScreenshot: false, isLivePhoto: false,
                                    burstID: nil, isProtected: false, isEligible: true)
        let current = SuggestionAnalysis(asset: asset, differenceHash: 0x1234, featurePrint: Data([1, 2, 3]),
                                         hasPastEvent: false, eventDates: nil, resourceDigest: "digest",
                                         resourceBytes: 42, checkedResources: true)
        let encoded = try JSONEncoder().encode(current)
        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "temporaryScreenshotKind")
        legacyObject.removeValue(forKey: "screenshotContentChecked")
        legacyObject.removeValue(forKey: "screenshotClassifierVersion")
        legacyObject.removeValue(forKey: "previewUnavailableAt")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)

        let decoded = try JSONDecoder().decode(SuggestionAnalysis.self, from: legacyData)
        #expect(decoded.temporaryScreenshotKind == nil)
        #expect(decoded.screenshotContentChecked == nil)
        #expect(decoded.screenshotClassifierVersion == nil)
        #expect(decoded.previewUnavailableAt == nil)
        #expect(decoded.matches(asset))
        #expect(decoded.differenceHash == current.differenceHash)
        #expect(decoded.featurePrint == current.featurePrint)
        #expect(decoded.resourceDigest == current.resourceDigest)
        #expect(decoded.resourceBytes == current.resourceBytes)
        #expect(decoded.checkedResources == current.checkedResources)
    }
}
