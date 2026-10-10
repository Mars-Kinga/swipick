import Foundation
import Testing
@testable import Zeying

struct SuggestionGroupingTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func asset(_ id: String, seconds: TimeInterval = 0, screenshot: Bool = false,
                       protected: Bool = false, live: Bool = false) -> SuggestionAsset {
        SuggestionAsset(id: id, modifiedAt: now, createdAt: now.addingTimeInterval(seconds), width: 1200, height: 1600,
                        isScreenshot: screenshot, isLivePhoto: live, burstID: nil,
                        isProtected: protected, isEligible: !protected)
    }

    private func analysis(_ asset: SuggestionAsset, hash: UInt64 = 0, digest: String? = nil,
                          screenshotKind: TemporaryScreenshotKind? = nil,
                          screenshotContentChecked: Bool? = nil,
                          hasPastEvent: Bool = false, eventDates: [Date]? = nil) -> SuggestionAnalysis {
        SuggestionAnalysis(asset: asset, differenceHash: hash, featurePrint: Data(), hasPastEvent: hasPastEvent,
                           eventDates: eventDates, temporaryScreenshotKind: screenshotKind,
                           screenshotContentChecked: screenshotContentChecked,
                           resourceDigest: digest, resourceBytes: digest == nil ? nil : 100, checkedResources: digest != nil)
    }

    @Test("只有明确主体且面部质量差异可靠时才生成人像建议")
    func portraitEvidenceCreatesVisibleSuggestion() {
        let a = asset("portrait-a"), b = asset("portrait-b", seconds: 2)
        var first = analysis(a)
        var second = analysis(b)
        first.portraitChecked = true
        second.portraitChecked = true
        first.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        second.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        first.portraitEvidence = SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: 0.62,
                                                            largestFaceArea: 0.10)
        second.portraitEvidence = SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: 0.625,
                                                             largestFaceArea: 0.11)
        first.portraitEvidence?.dominantFaceQuality = 0.62
        first.portraitEvidence?.dominantCenterX = 0.5
        first.portraitEvidence?.dominantCenterY = 0.5
        first.portraitEvidence?.secondLargestFaceArea = 0
        second.portraitEvidence?.dominantFaceQuality = 0.625
        second.portraitEvidence?.dominantCenterX = 0.52
        second.portraitEvidence?.dominantCenterY = 0.5
        second.portraitEvidence?.secondLargestFaceArea = 0
        var group = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: first, b.id: second], now: now) { _, _ in 0.10 }.first
        #expect(group?.hasPortraitRecommendation == false)
        second.portraitEvidence = SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: 0.34,
                                                             largestFaceArea: 0.11)
        second.portraitEvidence?.dominantFaceQuality = 0.34
        second.portraitEvidence?.dominantCenterX = 0.52
        second.portraitEvidence?.dominantCenterY = 0.5
        second.portraitEvidence?.secondLargestFaceArea = 0
        group = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: first, b.id: second], now: now) { _, _ in 0.10 }.first
        #expect(group?.hasPortraitRecommendation == true)
        #expect(group?.displayTitle == String(localized: "相似照片"))
        #expect(group?.portraitReason(for: a.id) != nil)
        #expect(group?.portraitReason(for: b.id) == nil)
    }

    @Test("精彩组合只建议质量接近且画面有差异的几张照片")
    func highlightKeepersFavorDistinctStrongShots() {
        let photos = (0..<9).map { asset("p\($0)", seconds: TimeInterval($0)) }
        let scores: [Float] = [0.85, 0.83, 0.81, 0.79, 0.75, 0.71, 0.68, 0.62, 0.58]
        let analyses = Dictionary(uniqueKeysWithValues: zip(photos, scores).map { pair in
            var value = analysis(pair.0)
            value.aestheticScore = pair.1
            return (pair.0.id, value)
        })
        let selected = SuggestionKeeperRanking.chooseHighlights(
            members: photos, analyses: analyses, reason: .nearbyShots, primaryID: "p0"
        ) { left, right in
            Set([left, right]) == Set(["p0", "p1"]) ? 0.04 : 0.2
        }
        #expect(selected == ["p0", "p2", "p3"])
        #expect(SuggestionKeeperRanking.chooseHighlights(
            members: photos, analyses: analyses, reason: .possibleVersions,
            primaryID: "p0", distance: { _, _ in 0.2 }) == ["p0"])
    }

    @Test("修图版与原图画面相近但资源不同，只给比较参考，不归入重复副本")
    func editedVersionsRemainSeparateChoices() {
        let a = asset("original"), b = asset("edited", seconds: 1000)
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: analysis(a, digest: "original-bytes"), b.id: analysis(b, digest: "edited-bytes")], now: now) { _, _ in 0.01 }
        #expect(groups.count == 1)
        #expect(groups.first?.kind == .similar)
        #expect(groups.first?.reason == .possibleVersions)
        #expect(groups.first?.recommendedKeepID == nil)
    }

    @Test("未经完整资源确认的视觉相近照片只能作为相近版本")
    func previewsCannotConfirmDuplicates() {
        let a = asset("a"), b = asset("b")
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: analysis(a), b.id: analysis(b)], now: now) { _, _ in 0.01 }
        #expect(groups.allSatisfy { $0.kind != .duplicates })
    }

    @Test("完整资源相同优先归组，并保护收藏参照，照片不重复出现")
    func confirmedCopiesTakePrecedence() {
        let a = asset("favorite", protected: true), b = asset("copy", screenshot: true)
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: analysis(a, digest: "same"), b.id: analysis(b, digest: "same")], now: now) { _, _ in 0 }
        #expect(groups.count == 1)
        #expect(groups.first?.reason == .identicalResources)
        #expect(groups.first?.recommendedKeepID == "favorite")
        #expect(groups.first?.protectedIDs == ["favorite"])
        #expect(groups.first?.knownBytes == 200)
    }

    @Test("相似链的两端不同，不应被串成同一组")
    func similarityIsNotTransitive() {
        let a = asset("a"), b = asset("b", seconds: 1), c = asset("c", seconds: 2)
        let analyses = ["a": analysis(a, hash: 0), "b": analysis(b, hash: 0xffff), "c": analysis(c, hash: 0xffffffff)]
        let groups = SuggestionGrouping.build(assets: [a, b, c], analyses: analyses, now: now) { left, right in
            Set([left, right]) == Set(["a", "c"]) ? 0.9 : 0.15
        }
        #expect(groups.count == 1)
        #expect(groups.first?.assetIDs == ["a", "b"])
        #expect(groups.first?.recommendedKeepID == nil)
    }

    @Test("几分钟内同一场景的多张照片可归入一组")
    func nearbySeriesCanContainMoreThanThreePhotos() {
        let photos = (0..<6).map { asset("scene-\($0)", seconds: TimeInterval($0 * 60)) }
        let analyses = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, analysis($0)) })
        let groups = SuggestionGrouping.build(assets: photos, analyses: analyses, now: now) { _, _ in 0.15 }
        #expect(groups.count == 1)
        #expect(groups.first?.assetIDs.count == 6)
        #expect(groups.first?.reason == .nearbyShots)
    }

    @Test("同一场景的多组相近照片合并为一组，不按两张拆分", arguments: [6, 10])
    func nearbyPairsStayInOneGroup(count: Int) {
        let photos = (0..<count).map { asset("selfie-\($0)", seconds: TimeInterval($0 * 12)) }
        let analyses = Dictionary(uniqueKeysWithValues: photos.enumerated().map { index, photo in
            (photo.id, analysis(photo, hash: UInt64(index / 2) * 0x0001_0001_0001_0001))
        })
        let pairByID = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.id, $0.offset / 2) })
        let groups = SuggestionGrouping.build(assets: photos, analyses: analyses, now: now) { left, right in
            pairByID[left] == pairByID[right] ? 0.04 : 0.31
        }
        #expect(groups.count == 1)
        #expect(Set(groups.first?.assetIDs ?? []) == Set(photos.map(\.id)))
        #expect(groups.first?.reason == .nearbyShots)
    }

    @Test("短时间内姿势变化的七张自拍归为一组，不混入相邻的不同照片")
    func quickSelfieSequenceStaysTogether() {
        let selfies = (0..<7).map { asset("selfie-\($0)", seconds: TimeInterval($0 * 9)) }
        let unrelated = asset("different-scene", seconds: 31)
        let photos = selfies + [unrelated]
        // Distances measured from the seven selfie thumbnails in the reported
        // example. Their different poses exceed the old 0.22 / 0.35 bounds.
        let values: [[Float]] = [
            [0, 0.239, 0.372, 0.369, 0.365, 0.336, 0.414],
            [0.239, 0, 0.345, 0.318, 0.392, 0.339, 0.406],
            [0.372, 0.345, 0, 0.249, 0.392, 0.368, 0.348],
            [0.369, 0.318, 0.249, 0, 0.411, 0.378, 0.372],
            [0.365, 0.392, 0.392, 0.411, 0, 0.219, 0.252],
            [0.336, 0.339, 0.368, 0.378, 0.219, 0, 0.262],
            [0.414, 0.406, 0.348, 0.372, 0.252, 0.262, 0]
        ]
        let indexByID = Dictionary(uniqueKeysWithValues: selfies.enumerated().map { ($0.element.id, $0.offset) })
        let hashes: [UInt64] = [
            0, 0x0000_0000_0000_01ff, 0x1234_5678_9abc_def0,
            0xfedc_ba98_7654_3210, 0x1111_2222_3333_4444,
            0x1111_2222_3333_4447, 0xaaaa_bbbb_cccc_dddd
        ]
        let analyses = Dictionary(uniqueKeysWithValues: photos.map { photo in
            let hash = indexByID[photo.id].map { hashes[$0] } ?? UInt64.max
            return (photo.id, analysis(photo, hash: hash))
        })
        let groups = SuggestionGrouping.build(assets: photos, analyses: analyses, now: now) { left, right in
            guard let first = indexByID[left], let second = indexByID[right] else { return 0.55 }
            return values[first][second]
        }
        #expect(groups.count == 1)
        #expect(Set(groups[0].assetIDs) == Set(selfies.map(\.id)))
        #expect(groups[0].reason == .nearbyShots)
    }

    @Test("姿势相近但间隔较久的照片仍使用严格的起组门槛")
    func looserSelfieThresholdRequiresBriefCaptureWindow() {
        let first = asset("first")
        let second = asset("second", seconds: 120)
        let groups = SuggestionGrouping.build(assets: [first, second], analyses: [
            first.id: analysis(first), second.id: analysis(second, hash: 0x1ff)
        ], now: now) { _, _ in 0.239 }
        #expect(groups.isEmpty)
    }

    @Test("同一时段不同场景仍分组，不因时间接近而合并")
    func nearbyButDifferentScenesStaySeparate() {
        let photos = (0..<4).map { asset("scene-\($0)", seconds: TimeInterval($0 * 8)) }
        let analyses = Dictionary(uniqueKeysWithValues: photos.enumerated().map { index, photo in
            (photo.id, analysis(photo, hash: UInt64(index / 2) * 0x0001_0001_0001_0001))
        })
        let pairByID = Dictionary(uniqueKeysWithValues: photos.enumerated().map { ($0.element.id, $0.offset / 2) })
        let groups = SuggestionGrouping.build(assets: photos, analyses: analyses, now: now) { left, right in
            pairByID[left] == pairByID[right] ? 0.04 : 0.55
        }
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.assetIDs.count == 2 })
    }

    @Test("没有可靠核心的两张照片不会仅凭宽松时段阈值成为建议")
    func nearbyWeakPairDoesNotCreateSuggestion() {
        let first = asset("first")
        let second = asset("second", seconds: 8)
        let groups = SuggestionGrouping.build(
            assets: [first, second],
            analyses: [first.id: analysis(first, hash: 0), second.id: analysis(second, hash: 0x0001_0001_0001_0001)],
            now: now
        ) { _, _ in 0.31 }
        #expect(groups.isEmpty)
    }

    @Test("同场景照片按时间交错时，找到可靠核心后回看先前跳过的照片")
    func interleavedPosesRejoinTheirScene() {
        let photos = (0..<4).map { asset("pose-\($0)", seconds: TimeInterval($0 * 2)) }
        let hashes: [UInt64] = [0, 0xffff, 0xffff_ffff, 0xffff_0000_ffff_0000]
        let analyses = Dictionary(uniqueKeysWithValues: photos.enumerated().map { index, photo in
            (photo.id, analysis(photo, hash: hashes[index]))
        })
        let closePair: Set<String> = [photos[0].id, photos[3].id]
        let otherPair: Set<String> = [photos[1].id, photos[2].id]
        let groups = SuggestionGrouping.build(assets: photos, analyses: analyses, now: now) { left, right in
            let pair = Set([left, right])
            return pair == closePair || pair == otherPair ? 0.19 : 0.29
        }
        #expect(groups.count == 1)
        #expect(Set(groups.first?.assetIDs ?? []) == Set(photos.map(\.id)))
    }

    @Test("Vision 给出明确美学评分时推荐较高者，不用拍摄时间代替审美")
    func aestheticsRanksSimilarPhotos() {
        let older = asset("older"), newer = asset("newer", seconds: 10)
        var olderAnalysis = analysis(older)
        olderAnalysis.aestheticScore = 0.38
        var newerAnalysis = analysis(newer)
        newerAnalysis.aestheticScore = 0.19
        let groups = SuggestionGrouping.build(assets: [older, newer], analyses: [
            older.id: olderAnalysis, newer.id: newerAnalysis
        ], now: now) { _, _ in 0.01 }
        #expect(groups.first?.recommendedKeepID == older.id)
        #expect(groups.first?.recommendationBasis == .visionAesthetics)
        #expect(abs((groups.first?.aestheticLead ?? 0) - 0.19) < 0.001)
    }

    @Test("评分未覆盖整组时暂不推荐，避免只分析一张就宣称最佳")
    func incompleteScoresDoNotRecommend() {
        let a = asset("a"), b = asset("b", seconds: 10)
        var scored = analysis(a)
        scored.aestheticScore = 0.9
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: scored, b.id: analysis(b)], now: now) { _, _ in 0.01 }
        #expect(groups.first?.recommendedKeepID == nil)
        #expect(groups.first?.aestheticEvaluationComplete == false)
    }

    @Test("Vision 分数打平时不捏造最佳照片，但保留每张分数供用户比较")
    func tiedScoresRemainAvailableWithoutInventingAWinner() {
        let a = asset("a"), b = asset("b", seconds: 10)
        var first = analysis(a)
        var second = analysis(b)
        first.aestheticScore = 0.47
        second.aestheticScore = 0.47
        first.aestheticChecked = true
        second.aestheticChecked = true
        let group = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: first, b.id: second], now: now) { _, _ in 0.01 }.first
        #expect(group?.recommendedKeepID == nil)
        #expect(group?.aestheticScores.count == 2)
        #expect(group?.aestheticEvaluationComplete == true)
    }

    @Test("整组美学评分失败后也结束比较状态，不让提示无限转圈")
    func failedScoresFinishComparison() {
        let a = asset("a"), b = asset("b", seconds: 10)
        var first = analysis(a)
        var second = analysis(b)
        first.aestheticChecked = true
        second.aestheticChecked = true
        let groups = SuggestionGrouping.build(assets: [a, b], analyses: [a.id: first, b.id: second], now: now) { _, _ in 0.01 }
        #expect(groups.first?.kind == .similar)
        #expect(groups.first?.aestheticEvaluationComplete == true)
        #expect(groups.first?.recommendedKeepID == nil)
    }

    @Test("缓存了内容证据的旧截图无需再次下载预览，近期截图仍不进入时间建议")
    func oldScreenshotsNeedNoImageDownload() {
        let old = asset("old", seconds: -100 * 86_400, screenshot: true)
        let fresh = asset("new", screenshot: true)
        let groups = SuggestionGrouping.build(
            assets: [fresh, old],
            analyses: [old.id: analysis(old, screenshotKind: .verificationCodes, screenshotContentChecked: true)],
            now: now
        ) { _, _ in nil }
        #expect(groups.count == 1)
        #expect(groups.first?.assetIDs == ["old"])
        #expect(groups.first?.kind == .screenshots)
        #expect(groups.first?.reason == .olderVerificationCodes)
        #expect(groups.first?.recommendedKeepID == nil)
    }

    @Test("照片修改或尺寸变化使缓存失效，收藏变化仍可复用图像特征")
    func cacheTracksImageChanges() {
        let original = asset("a")
        let cached = analysis(original)
        var protected = original
        protected.isProtected = true
        #expect(cached.matches(protected))
        let changed = SuggestionAsset(id: original.id, modifiedAt: now.addingTimeInterval(1), createdAt: original.createdAt,
                                      width: original.width, height: original.height, isScreenshot: false, isLivePhoto: false,
                                      burstID: nil, isProtected: false, isEligible: true)
        #expect(!cached.matches(changed))
    }

    @Test("活动日期规则需要活动语境、完整年份与合法的过去日期")
    func eventDatesAreConservative() {
        #expect(ScreenshotEventDate.hasPastEvent(in: "音乐会 2020年9月12日 入场", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "订单 2020-09-12", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "活动 2099-09-12", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "演出 2020-02-31", now: now))
        #expect(!ScreenshotEventDate.hasPastEvent(in: "演出 9月12日", now: now))
    }
}
