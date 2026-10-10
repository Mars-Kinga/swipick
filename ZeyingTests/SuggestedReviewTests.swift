import Foundation
import SwiftData
import Testing
@testable import Zeying

@MainActor
struct SuggestedReviewTests {
    @Test("推荐照片置顶，其余按 Vision 分数降序，缺失分数的照片排在最后")
    func reviewPhotosShowRecommendationBeforeScoreOrder() {
        var group = CleanupSuggestion(
            id: "scene", kind: .similar, reason: .nearbyShots,
            assetIDs: ["a", "b", "c", "d", "e"], recommendedKeepID: "d",
            protectedIDs: [], knownBytes: nil, newestDate: nil
        )
        group.aestheticScores = ["a": 0.59, "b": 0.65, "c": 0.65, "d": 0.40]
        #expect(SuggestionReviewQueue.orderedAssetIDs(in: group) == ["d", "b", "c", "a", "e"])

        group.recommendedKeepID = nil
        #expect(SuggestionReviewQueue.orderedAssetIDs(in: group) == ["b", "c", "a", "d", "e"])
    }

    @Test("有人像建议的照片紧跟推荐保留项，网格和放大查看共用顺序")
    func portraitSuggestionFollowsPrimaryKeeper() {
        var group = CleanupSuggestion(
            id: "portraits", kind: .similar, reason: .nearbyShots,
            assetIDs: ["a", "b", "c"], recommendedKeepID: "a",
            protectedIDs: [], knownBytes: nil, newestDate: nil
        )
        group.aestheticScores = ["a": 0.595, "b": 0.555, "c": 0.557]
        #expect(SuggestionReviewQueue.orderedAssetIDs(in: group) == ["a", "c", "b"])

        group.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        group.portraitEvidence = [
            "a": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.495, largestFaceArea: 0.057),
            "b": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.511, largestFaceArea: 0.060),
            "c": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.480, largestFaceArea: 0.079)
        ]
        #expect(group.portraitReason(for: "b") != nil)
        #expect(SuggestionReviewQueue.orderedAssetIDs(in: group) == ["a", "b", "c"])
    }

    @Test("一键帮选优先采用可见建议，没有建议时选择画面中的第一张")
    func chooseKeepersUsesVisibleSuggestionOrFirstPhoto() {
        var group = CleanupSuggestion(
            id: "scene", kind: .similar, reason: .nearbyShots,
            assetIDs: ["a", "b", "c"], recommendedKeepID: "b",
            protectedIDs: [], knownBytes: nil, newestDate: nil
        )
        let visible = SuggestionReviewQueue.orderedAssetIDs(in: group)
        #expect(SuggestionReviewQueue.keepersToSelect(in: group, visibleAssetIDs: visible) == ["b"])

        group.suggestedKeeperIDs = ["b", "c"]
        #expect(SuggestionReviewQueue.keepersToSelect(in: group, visibleAssetIDs: visible) == ["b", "c"])

        group.recommendedKeepID = nil
        group.suggestedKeeperIDs = nil
        #expect(SuggestionReviewQueue.keepersToSelect(
            in: group, visibleAssetIDs: SuggestionReviewQueue.orderedAssetIDs(in: group)) == ["a"])

        group.recommendedKeepID = "missing"
        #expect(SuggestionReviewQueue.keepersToSelect(in: group, visibleAssetIDs: ["c", "a"]) == ["c"])
        #expect(SuggestionReviewQueue.keepersToSelect(in: group, visibleAssetIDs: []).isEmpty)
    }

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

    @Test("人像建议比较面部质量，不把路人数量当作优势")
    func portraitReasonsRequireComparativeEvidence() {
        func portrait(faces: Int, quality: Float, area: Float, secondArea: Float = 0,
                      x: Float = 0.5) -> SuggestionPortraitEvidence {
            var evidence = SuggestionPortraitEvidence(faceCount: faces, averageCaptureQuality: quality,
                                                      largestFaceArea: area)
            evidence.dominantFaceQuality = quality
            evidence.dominantCenterX = x
            evidence.dominantCenterY = 0.5
            evidence.secondLargestFaceArea = secondArea
            return evidence
        }
        var group = CleanupSuggestion(id: "portrait", kind: .similar, reason: .nearbyShots,
                                      assetIDs: ["a", "b"], recommendedKeepID: "a",
                                      protectedIDs: [], knownBytes: nil, newestDate: nil)
        group.portraitEvaluationComplete = true
        group.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        group.portraitEvidence = [
            "a": portrait(faces: 2, quality: 0.80, area: 0.15, secondArea: 0.015),
            "b": portrait(faces: 1, quality: 0.55, area: 0.14)
        ]
        #expect(group.portraitReason(for: "a") == String(localized: "人物面部成像质量更好"))
        #expect(group.hasPortraitRecommendation)
        #expect(group.portraitReason(for: "b") == nil)
        group.portraitEvidence?["b"] = portrait(faces: 3, quality: 0.795, area: 0.14, secondArea: 0.07)
        #expect(group.portraitReason(for: "a") == nil)
        #expect(!group.hasPortraitRecommendation)
        group.portraitEvidence?["b"] = portrait(faces: 1, quality: 0.55, area: 0.02)
        #expect(group.portraitReason(for: "a") != nil)
        group.portraitEvidence?["b"] = portrait(faces: 1, quality: 0.55, area: 0.005)
        #expect(!group.hasPortraitRecommendation)
    }

    @Test("锁定保留的照片不阻止其他人像建议；面部质量缺失时可参考画面评分")
    func portraitReasonsIncludeOtherPhotosInProtectedGroups() {
        var group = CleanupSuggestion(id: "protected", kind: .similar, reason: .nearbyShots,
                                      assetIDs: ["a", "b"], recommendedKeepID: "a",
                                      protectedIDs: ["a"], knownBytes: nil, newestDate: nil)
        group.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        group.portraitEvaluationComplete = true
        group.portraitEvidence = [
            "a": SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: 0.52, largestFaceArea: 0.03),
            "b": SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: 0.78, largestFaceArea: 0.03)
        ]
        #expect(group.portraitReason(for: "b") == String(localized: "人物面部成像质量更好"))
        group.portraitEvidence = [
            "a": SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: nil, largestFaceArea: 0.03),
            "b": SuggestionPortraitEvidence(faceCount: 1, averageCaptureQuality: nil, largestFaceArea: 0.03)
        ]
        group.aestheticScores = ["a": 0.60, "b": 0.83]
        #expect(group.portraitReason(for: "b") == String(localized: "人像画面整体观感更好"))
    }

    @Test("接近的清晰人像也给出如实的相对评分提示")
    func closePortraitScoresStillProduceHelpfulHints() {
        var group = CleanupSuggestion(id: "selfie", kind: .similar, reason: .nearbyShots,
                                      assetIDs: ["a", "b", "c"], recommendedKeepID: "a",
                                      protectedIDs: [], knownBytes: nil, newestDate: nil)
        group.portraitClassifierVersion = SuggestionPortraitEvidence.classifierVersion
        group.portraitEvaluationComplete = true
        group.portraitEvidence = [
            "a": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.495, largestFaceArea: 0.057),
            "b": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.511, largestFaceArea: 0.060),
            "c": SuggestionPortraitEvidence(faceCount: 2, averageCaptureQuality: 0.480, largestFaceArea: 0.079)
        ]
        group.aestheticScores = ["a": 0.595, "b": 0.555, "c": 0.557]
        #expect(group.portraitReason(for: "a") == String(localized: "人像画面评分略高"))
        #expect(group.portraitReason(for: "b") == String(localized: "面部成像评分略高"))
        #expect(group.hasPortraitRecommendation)
    }

    @Test("顺序学习只保存汇总行为，撤销和重置生效")
    func orderLearningPersistsAndCanReset() throws {
        let suite = "suggestion-order-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let group = CleanupSuggestion(id: "group", kind: .similar, reason: .nearbyShots,
                                      assetIDs: ["a", "b"], recommendedKeepID: nil,
                                      protectedIDs: [], knownBytes: nil, newestDate: nil)
        let service = PhotoSuggestionService(defaults: defaults)
        service.recordReview(of: group, kept: 1)
        #expect(service.orderLearning.score(for: .nearbyShots) > 0)
        service.undoRecordedReview(of: group, kept: 1)
        #expect(service.orderLearning.score(for: .nearbyShots) == 0)
        service.skip(group)
        service.skip(group)
        let reopened = PhotoSuggestionService(defaults: defaults)
        #expect(reopened.orderLearning.score(for: .nearbyShots) < 0)
        reopened.resetOrderLearning()
        #expect(PhotoSuggestionService(defaults: defaults).orderLearning.hasHistory == false)
    }
}
